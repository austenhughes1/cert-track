# A flag on a Certificate or ImportItem whose image is too small or blurry, when that kept something
# from being read (owner, Nov 5, 2026). Going by what failed rather than a sharpness score: a soft
# photo that reads fine isn't flagged. Imports::ImageQuality decides.
#
#   qr_unreadable  a QR code appears to be there, but it couldn't be decoded
#   hard_to_read   a scan or photo where details couldn't be read
module ImageQualityFlags
  extend ActiveSupport::Concern

  SENTENCES = {
    "qr_unreadable" => "A QR code appears to be on this file, but it couldn't be read: the image is too small or blurry.",
    "hard_to_read" => "Some details couldn't be read from this file: the image may be too small or blurry."
  }.freeze
  ASK = "Ask for a clearer copy.".freeze

  def quality_flagged?
    quality_flags.present?
  end

  def quality_sentences
    Array(quality_flags).filter_map { |flag| SENTENCES[flag] }
  end
end
