require "application_system_test_case"

class CatchFormNativePhotoTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club, name: "Joe")
    create(:species, club: @club, name: "Walleye")
  end

  # Merges attach->preview, dismiss-retake->kept, and accept-retake->cleared
  # into one continuous flow on the same form.
  test "attaching a photo shows the preview; Retake asks before clearing it" do
    visit_catch_form_with_photo

    # Preview becomes visible, Retake appears, and the form's missing-field
    # status no longer asks for a photo.
    assert page.has_selector?("img[data-photo-capture-target='preview']", visible: true, wait: 5),
           "attach: the preview image should render"
    assert page.has_selector?("button[data-photo-capture-target='retakeButton']", visible: true, wait: 5),
           "attach: the Retake button should appear"
    assert page.has_no_text?("Take a photo first.", wait: 5),
           "attach: the missing-photo prompt should clear"
    assert_match(/sample_walleye\.jpg\z/, photo_input_value,
                 "attach: the file input should hold the chosen file")

    dismiss_confirm do
      click_button "Retake"
    end

    # retake() returned before clearing the input, so the chosen file is still
    # attached and the preview still renders.
    assert page.has_selector?("img[data-photo-capture-target='preview']", visible: true, wait: 5),
           "dismiss retake: the preview should still render"
    assert page.has_no_text?("Take a photo first.", wait: 5),
           "dismiss retake: the missing-photo prompt should stay cleared"
    assert_match(/sample_walleye\.jpg\z/, photo_input_value,
                 "dismiss retake: the file should stay attached")

    accept_confirm do
      click_button "Retake"
    end

    # retake() ran past the guard and cleared the input so a re-pick of the same
    # file still fires a change event. The OS camera itself can't open headless.
    assert_equal "", photo_input_value, "accept retake: the file input should clear"
  end

  private

  # Signs in, opens the catch form, and attaches a photo — the starting state
  # for every test in this file.
  def visit_catch_form_with_photo
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit new_catch_path

    find("select#catch_species_id").select("Walleye")
    fill_in "catch_length_inches", with: "18"

    # The input is display:none (Tailwind `hidden`); Cuprite can still set it.
    input = find("input[data-photo-capture-target='input']", visible: :all)
    input.set(Rails.root.join("test/fixtures/files/sample_walleye.jpg"))
  end

  def photo_input_value
    page.evaluate_script(
      "document.querySelector(\"input[data-photo-capture-target='input']\").value"
    )
  end
end
