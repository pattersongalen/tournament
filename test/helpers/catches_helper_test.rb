require "test_helper"

class CatchesHelperTest < ActionView::TestCase
  # next_range(day, current_start, current_end) → [target_start, target_end]
  # Encodes the tap-rule table from the spec.

  def call(day, current_start, current_end)
    next_range(day, current_start, current_end)
  end

  test "next_range follows the tap-selection rule table" do
    d5  = Date.new(2026, 5, 5)
    d8  = Date.new(2026, 5, 8)
    d12 = Date.new(2026, 5, 12)
    d20 = Date.new(2026, 5, 20)

    {
      "no current selection: tap selects single day"          => [[d5, nil, nil], [d5, d5]],
      "single day, tap same day: no change"                   => [[d5, d5, d5], [d5, d5]],
      "single day, tap a later day: extends forward"          => [[d12, d5, d5], [d5, d12]],
      "single day, tap an earlier day: extends backward"      => [[d5, d12, d12], [d5, d12]],
      "existing range, tap any day: resets to single day"     => [[d20, d5, d12], [d20, d20]],
      "existing range, tap inside: also resets to single day" => [[d8, d5, d12], [d8, d8]]
    }.each do |label, (args, expected)|
      assert_equal expected, call(*args), label
    end
  end

  test "maps_url_for builds a Google Maps query URL from full-precision coords" do
    c = Struct.new(:latitude, :longitude).new(49.123456, -103.987654)
    assert_equal "https://maps.google.com/?q=49.123456,-103.987654", maps_url_for(c)
  end

  test "month_calendar_link_url encodes start/end for single-day and range selections" do
    s = Date.new(2026, 5, 5)
    d = Date.new(2026, 5, 12)
    {
      "no current selection: start=end=tapped" =>
        { d: s, current_start: nil, current_end: nil, start: "2026-05-05", end: "2026-05-05" },
      "single day + later tap: encodes range" =>
        { d: d, current_start: s, current_end: s, start: "2026-05-05", end: "2026-05-12" }
    }.each do |label, c|
      url = month_calendar_link_url(c[:d], current_start: c[:current_start], current_end: c[:current_end],
                                     params: {}, path_helper: :catches_path)
      if c[:current_start].nil?
        assert_match %r{\?.*start=#{c[:start]}}, url, label
        assert_match %r{\?.*end=#{c[:end]}}, url, label
      else
        assert_match "start=#{c[:start]}", url, label
        assert_match "end=#{c[:end]}", url, label
      end
    end
  end

  test "month_calendar_link_url preserves query params but drops controller/action keys" do
    url = month_calendar_link_url(Date.new(2026, 5, 5),
                                  current_start: nil, current_end: nil,
                                  params: { species: "3", sort: "longest", controller: "catches", action: "index" },
                                  path_helper: :catches_path)
    assert_match "species=3", url
    assert_match "sort=longest", url
    assert_match "start=2026-05-05", url
    refute_match "controller=", url
    refute_match "action=", url
  end

  test "flag_label renders known flags with friendly text" do
    {
      "out_of_province"    => "outside Saskatchewan",
      "screenshot_suspect" => "possible screenshot"
    }.each do |flag, label_text|
      assert_equal label_text, flag_label(flag), flag
    end
  end

  test "visible_flags_for hides screenshot_suspect unless the viewer can review catches" do
    catch_record = Catch.new(flags: %w[missing_gps screenshot_suspect])
    {
      false => %w[missing_gps],
      true  => %w[missing_gps screenshot_suspect]
    }.each do |can_review, expected|
      define_singleton_method(:can_review_catch?) { |_| can_review }
      assert_equal expected, visible_flags_for(catch_record), "can_review_catch?=#{can_review}"
    end
  end

  # --- JPEG-variant photo display helpers (iOS HEIC support) ---

  def attached_photo(path: "test/fixtures/files/sample_walleye.jpg", content_type: "image/jpeg", filename: "sample_walleye.jpg")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(Rails.root.join(path)),
      filename: filename,
      content_type: content_type
    )
    record = Catch.new
    record.photo.attach(blob)
    record.photo
  end

  # These exercise the helpers themselves (not a re-implementation of their
  # internals) so they fail if a helper is changed to serve the raw original.
  # A variant routes through /representations/; a raw original through /blobs/.

  test "thumb, photo_full, and photo_src_url all route through a processed variant, not the raw original" do
    photo = attached_photo
    {
      "thumb"         => thumb(photo),
      "photo_full"    => photo_full(photo),
      "photo_src_url" => photo_src_url(photo)
    }.each do |label, output|
      assert_includes output, "/rails/active_storage/representations/", label
      refute_includes output, "/rails/active_storage/blobs/", label
    end
    assert_match %r{<img }, thumb(photo)
    assert_match %r{loading="lazy"}, thumb(photo)
    assert_match %r{<img }, photo_full(photo)
  end

  test "photo_download_url serves a stripped, full-resolution JPEG variant for any original" do
    # The raw original ships full-precision GPS EXIF — an Android native-camera
    # JPEG saved by a rival is the honey-hole leak the strip exists to close.
    jpeg_url = photo_download_url(attached_photo)
    assert_includes jpeg_url, "/rails/active_storage/representations/"
    refute_includes jpeg_url, "/rails/active_storage/blobs/"

    heic = attached_photo(path: "test/fixtures/files/sample_walleye.heic",
                           content_type: "image/heic", filename: "sample_walleye.heic")
    # Non-JPEG goes through a variant (representation) too, not the raw original.
    assert_includes photo_download_url(heic), "/rails/active_storage/representations/"

    # Downloads are the largest quality we can serve (user decision
    # 2026-08-08): no resize limit — the unbounded first-tap transcode is an
    # accepted cost — and a high encode Q, but ALWAYS the metadata strip.
    variation_key = jpeg_url[%r{/representations/(?:redirect|proxy)/[^/]+/([^/]+)}, 1]
    transformations = ActiveStorage::Variation.decode(variation_key).transformations
    assert_nil transformations[:resize_to_limit]
    assert_equal true, transformations[:saver][:strip]
    assert_equal CatchesHelper::DOWNLOAD_JPEG_QUALITY, transformations[:saver][:Q]
    assert_equal "jpeg", transformations[:format].to_s
  end

  # --- EXIF (GPS) stripping from served variants (privacy: defeats saved-photo GPS leak) ---

  test "stripped_jpeg_variant converts to sRGB before the strip discards the profile" do
    # Minitest::Mock isn't available in this environment (minitest 6.0.6 split
    # Mock/Stub into a separate gem that isn't a dependency here), so this
    # matches the file's existing define_singleton_method stubbing style
    # rather than the brief's Mock example.
    captured = nil
    attachment = Object.new
    attachment.define_singleton_method(:variant) { |**opts| captured = opts; :a_variant }
    stripped_jpeg_variant(attachment, size: [400, 400])

    assert_equal :srgb, captured[:colourspace],
                 "1-band sources must be widened to 3 bands or icc_transform hard-fails"
    assert_equal "srgb", captured[:icc_transform]
    assert_equal({ strip: true }, captured[:saver])
    assert_equal :jpeg, captured[:format]
    assert_equal [400, 400], captured[:resize_to_limit]
    # Order matters: Active Storage applies the transformations in hash order, so
    # the conversion has to land before the saver strips the profile it reads.
    keys = captured.keys.map(&:to_s)
    assert keys.index("icc_transform") < keys.index("saver"),
           "icc_transform must be applied before the saver strip: #{keys.inspect}"
    assert keys.index("colourspace") < keys.index("icc_transform"),
           "colourspace must widen the image before icc_transform: #{keys.inspect}"
  end

  test "vips variant pipeline with strip removes EXIF GPS end-to-end" do
    require "image_processing/vips"
    src = Vips::Image.new_from_file(file_fixture("sample_walleye.jpg").to_s)
    tagged = src.mutate do |m|
      m.set_type!(GObject::GSTR_TYPE, "exif-ifd3-GPSLatitude", "49/1 24/1 30/1")
    end
    Dir.mktmpdir do |dir|
      tagged_path = File.join(dir, "gps.jpg")
      tagged.write_to_file(tagged_path)
      assert Vips::Image.new_from_file(tagged_path).get_fields.any? { |f| f.include?("GPS") },
             "precondition: tagged source must carry GPS EXIF"
      out = ImageProcessing::Vips.source(tagged_path)
        .resize_to_limit(400, 400).convert("jpg").saver(strip: true).call
      fields = Vips::Image.new_from_file(out.path).get_fields
      assert fields.none? { |f| f.include?("GPS") }, "GPS EXIF survived: #{fields.grep(/GPS/)}"
    end
  end

  # --- Colour fidelity: the strip drops the ICC profile too (libvips 8.14 has no
  # granular `keep:`), so the pixels must be converted to sRGB BEFORE stripping.
  # Without the conversion, a Display-P3 iPhone photo ships wide-gamut pixels
  # with no profile and every browser renders it oversaturated.

  # A wide-gamut ICC profile to tag a test source with. Not every image has one
  # installed, so the end-to-end pixel test skips rather than fails without it.
  WIDE_GAMUT_PROFILES = %w[
    /usr/share/color/icc/ghostscript/a98.icc
    /usr/share/color/icc/ghostscript/rommrgb.icc
  ].freeze

  test "the served variant pipeline bakes a wide-gamut profile into sRGB pixels" do
    require "image_processing/vips"
    profile = WIDE_GAMUT_PROFILES.find { |p| File.exist?(p) }
    skip "no wide-gamut ICC profile installed to build a test source from" unless profile

    Dir.mktmpdir do |dir|
      # A saturated RGB source tagged wide-gamut — stands in for a Display-P3 iPhone photo.
      src = File.join(dir, "wide.jpg")
      r = (Vips::Image.xyz(300, 200)[0] * 255 / 300).cast(:uchar)
      g = (Vips::Image.xyz(300, 200)[1] * 255 / 200).cast(:uchar)
      r.bandjoin([g, (r * 0 + 200).cast(:uchar)]).copy(interpretation: :srgb)
        .jpegsave(src, Q: 95, profile: profile)

      tagged = Vips::Image.new_from_file(src)
      assert_includes tagged.get_fields, "icc-profile-data", "precondition: source must be tagged"
      ideal = tagged.icc_transform("srgb")   # what the photo should look like once untagged

      # Hold the Tempfiles: dropping the reference lets the finalizer delete the
      # file out from under vips before it is read.
      served_file = ImageProcessing::Vips.source(src).resize_to_limit(400, 400)
        .colourspace(:srgb).icc_transform("srgb")
        .convert("jpg").saver(strip: true, Q: 95).call
      naive_file = ImageProcessing::Vips.source(src).resize_to_limit(400, 400)
        .convert("jpg").saver(strip: true, Q: 95).call
      served = Vips::Image.new_from_file(served_file.path)
      naive  = Vips::Image.new_from_file(naive_file.path)

      delta = ->(img) {
        (ideal.extract_band(0, n: 3).cast(:float) - img.extract_band(0, n: 3).cast(:float)).abs.avg
      }
      # The converted variant lands on the intended colours; a bare strip does not.
      assert delta.(served) < 2.0, "converted variant drifted from sRGB: mean #{delta.(served).round(2)}"
      assert delta.(naive) > 5.0,
             "precondition: a bare strip should visibly shift colour (mean #{delta.(naive).round(2)})"
    end
  end

  test "the sRGB conversion still handles the image shapes members actually upload" do
    require "image_processing/vips"
    Dir.mktmpdir do |dir|
      # 1-band grayscale is the shape that makes a bare icc_transform raise
      # "unable to load or find any compatible input profile".
      gray = File.join(dir, "gray.jpg")
      Vips::Image.black(300, 200).linear(1, 128).cast(:uchar)
        .copy(interpretation: :"b-w").jpegsave(gray, Q: 90)
      # An untagged 3-band sRGB photo — the common Android case.
      plain = File.join(dir, "plain.jpg")
      c = (Vips::Image.xyz(300, 200)[0] * 255 / 300).cast(:uchar)
      c.bandjoin([c, c]).copy(interpretation: :srgb).jpegsave(plain, Q: 90)

      { "grayscale" => gray, "untagged sRGB" => plain }.each do |label, path|
        out = ImageProcessing::Vips.source(path).resize_to_limit(400, 400)
          .colourspace(:srgb).icc_transform("srgb").convert("jpg").saver(strip: true).call
        assert File.size(out.path).positive?, "#{label} produced an empty variant"
      end
    end
  end

  test "the sRGB conversion survives the HEIC (iOS) transcode through the real helper" do
    photo = attached_photo(path: "test/fixtures/files/sample_walleye.heic",
                           content_type: "image/heic", filename: "sample_walleye.heic")
    processed = stripped_jpeg_variant(photo, size: [400, 400]).processed
    assert_equal "image/jpeg", processed.image.blob.content_type
  end
end
