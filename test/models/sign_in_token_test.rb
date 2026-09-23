require "test_helper"

class SignInTokenTest < ActiveSupport::TestCase
  # Clubless user so each test below can stage memberships explicitly.
  setup { @user = create(:user, club: nil) }

  test "is created with a uuid token and 30-minute expiry" do
    token = SignInToken.issue!(user: @user)
    assert_match(/\A[0-9a-f-]{36}\z/, token.token)
    assert_in_delta 30.minutes.from_now, token.expires_at, 5
    assert_nil token.used_at
  end

  test "consume! marks the token used and returns the record" do
    token = SignInToken.issue!(user: @user)
    record = SignInToken.consume!(token.token)
    assert_equal token, record
    assert_equal @user, record.user
    assert_not_nil token.reload.used_at
  end

  test "consume! returns nil for unknown, expired, already-used, or code-kind tokens" do
    expired = SignInToken.issue!(user: @user)
    expired.update!(expires_at: 1.minute.ago)

    used = SignInToken.issue!(user: @user)
    SignInToken.consume!(used.token)

    code = SignInToken.issue_code!(user: @user)

    {
      "unknown token"      => "nope",
      "expired token"      => expired.token,
      "already-used token" => used.token,
      "code-kind token"    => code.token
    }.each do |label, token|
      assert_nil SignInToken.consume!(token), label
    end
  end

  test "issue_code! creates an 8-digit code valid 10 minutes" do
    code = SignInToken.issue_code!(user: @user)
    assert_match(/\A\d{8}\z/, code.token)
    assert_equal "code", code.kind
    assert_in_delta 10.minutes.from_now, code.expires_at, 5
  end

  # Issuing must NOT invalidate other open codes: the magic-link email path
  # auto-issues a code from the public, unauthenticated sign-in form, so
  # invalidation would let anyone who knows a member's email kill an
  # organizer-issued code before the member can type it in.
  test "issue_code! leaves prior open codes valid, so an older one can still be consumed" do
    first = SignInToken.issue_code!(user: @user)
    SignInToken.issue_code!(user: @user)
    assert_nil first.reload.used_at, "issuing a new code should not invalidate the old one"

    record = SignInToken.consume_code!(email: @user.email, code: first.token)
    assert_equal first, record
    assert_not_nil first.reload.used_at
  end

  # With codes coexisting, a wrong try must burn an attempt on every open code —
  # otherwise issuing fresh codes would hand a brute-forcer a clean counter.
  test "wrong tries count against every open code, locking each after MAX_ATTEMPTS" do
    first  = SignInToken.issue_code!(user: @user)
    second = SignInToken.issue_code!(user: @user)
    SignInToken::CODE_MAX_ATTEMPTS.times do
      assert_nil SignInToken.consume_code!(email: @user.email, code: "00000000")
    end
    assert_not_nil first.reload.used_at
    assert_not_nil second.reload.used_at

    # both are now locked out, even when the correct code is finally given
    assert_nil SignInToken.consume_code!(email: @user.email, code: first.token), "first stays locked"
    assert_nil SignInToken.consume_code!(email: @user.email, code: second.token), "second stays locked"
  end

  # Wrong guesses are free for anyone who knows the email (the public form
  # proves nothing), so they must not be able to kill a code an organizer just
  # read out — that's the grief coexistence exists to prevent. Staff-issued
  # codes ride on the TTL and the submit_code rate limit instead.
  test "wrong tries do not burn an organizer-issued code" do
    organizer = create(:user)
    issued = SignInToken.issue_code!(user: @user, issued_by: organizer)
    (SignInToken::CODE_MAX_ATTEMPTS + 1).times do
      assert_nil SignInToken.consume_code!(email: @user.email, code: "00000000")
    end
    assert_nil issued.reload.used_at
    assert_equal issued, SignInToken.consume_code!(email: @user.email, code: issued.token)
  end

  test "consume_code! signs in when email and code match" do
    code = SignInToken.issue_code!(user: @user)
    record = SignInToken.consume_code!(email: @user.email, code: code.token)
    assert_equal code, record
    assert_equal @user, record.user
    assert_not_nil code.reload.used_at
  end

  test "consume_code! returns nil on email mismatch or when no open code exists" do
    assert_nil SignInToken.consume_code!(email: @user.email, code: "12345678"), "no open code exists"

    code = SignInToken.issue_code!(user: @user)
    assert_nil SignInToken.consume_code!(email: "wrong@example.com", code: code.token), "email mismatch"
    assert_nil code.reload.used_at
  end

  test "consume! and consume_code! return nil for a deactivated user" do
    token = SignInToken.issue!(user: @user)
    code  = SignInToken.issue_code!(user: @user)
    @user.update!(deactivated_at: Time.current)

    assert_nil SignInToken.consume!(token.token), "consume!"
    assert_nil token.reload.used_at

    assert_nil SignInToken.consume_code!(email: @user.email, code: code.token), "consume_code!"
    assert_nil code.reload.used_at
  end

  # Simulates a TOCTOU race against consume!: in-memory used_at is still nil,
  # but the DB row was claimed by a parallel request between find_by and the
  # atomic update. The WHERE used_at IS NULL guard makes the second call miss.
  test "consume! does not double-consume when the row is claimed mid-flight" do
    token = SignInToken.issue!(user: @user)
    SignInToken.where(id: token.id).update_all(used_at: 1.second.ago)
    assert_nil SignInToken.consume!(token.token)
  end

  # Direct test of the atomic primitive. consume_code!'s race window opens
  # after .open.first returns a record, and a single-threaded test can't
  # easily reproduce that — but if the primitive is atomic, the race is closed.
  test "claim only succeeds once for the same row" do
    code = SignInToken.issue_code!(user: @user)
    assert SignInToken.send(:claim, code), "first claim should win"
    assert_not SignInToken.send(:claim, code), "second claim should miss"
  end

  test "issue!/issue_code! resolve club from an explicit arg or membership fallback" do
    {
      "issue! uses explicit club" => -> {
        user = create(:user, club: nil)
        club_a = create(:club)
        create(:club_membership, user: user, club: club_a, role: :member)
        [SignInToken.issue!(user: user, club: club_a).club, club_a]
      },
      "issue! falls back to first active membership when club not given" => -> {
        user = create(:user, club: nil)
        club_a = create(:club)
        create(:club_membership, user: user, club: club_a, role: :member)
        [SignInToken.issue!(user: user).club, club_a]
      },
      "issue! sets nil club when user has no memberships" => -> {
        user = create(:user, club: nil)
        [SignInToken.issue!(user: user).club, nil]
      },
      "issue! ignores deactivated memberships in fallback" => -> {
        user = create(:user, club: nil)
        club_a = create(:club)
        create(:club_membership, user: user, club: club_a, deactivated_at: Time.current)
        [SignInToken.issue!(user: user).club, nil]
      },
      "issue_code! stores explicit club" => -> {
        user = create(:user, club: nil)
        club_a = create(:club)
        [SignInToken.issue_code!(user: user, club: club_a).club, club_a]
      },
      "issue! fallback prefers the older membership when user is in multiple clubs" => -> {
        user = create(:user, club: nil)
        older = create(:club)
        newer = create(:club)
        create(:club_membership, user: user, club: older, role: :member, created_at: 2.days.ago)
        create(:club_membership, user: user, club: newer, role: :member, created_at: 1.day.ago)
        [SignInToken.issue!(user: user).club, older]
      }
    }.each do |label, setup|
      actual, expected = setup.call
      expected.nil? ? assert_nil(actual, label) : assert_equal(expected, actual, label)
    end
  end

  test "issue!/issue_code! record issued_by when given, nil otherwise" do
    issuer = create(:user)
    {
      "issue! records the granter"       => [SignInToken.issue!(user: @user, issued_by: issuer).issued_by_user, issuer],
      "issue! nil when not given"        => [SignInToken.issue!(user: @user).issued_by_user, nil],
      "issue_code! records the granter"  => [SignInToken.issue_code!(user: @user, issued_by: issuer).issued_by_user, issuer],
      "issue_code! nil when not given"   => [SignInToken.issue_code!(user: @user).issued_by_user, nil]
    }.each do |label, (actual, expected)|
      expected.nil? ? assert_nil(actual, label) : assert_equal(expected, actual, label)
    end
  end
end
