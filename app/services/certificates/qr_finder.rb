require "vips"

module Certificates
  # Whether an image shows a QR code, read or not (docs/PLAN.md, Phase 3b). A QR code has three
  # square corner marks whose dark and light bands run 1:1:3:1:1 across and down, and nothing else
  # on a certificate usually does. Used on a page Certificates::QrReader decoded nothing from, to
  # tell "no QR code" from "a QR code too small or blurry to read". It never reads the code.
  #
  #   Certificates::QrFinder.new("page.png").present? # => true
  #
  # A small code's marks only separate once enlarged, so the image is checked at each of SCALES, up
  # to MAX_SIDE. A candidate is compared module by module with a real mark, and three must sit at a
  # code's corners, far enough apart for a code's smallest size, so a certificate's decorative border
  # doesn't count. A code at about a pixel a module has no marks left, only a small square of dense
  # mid-grey noise, so that counts too (fine_print_square?), tuned on one real phone screenshot;
  # Imports::ImageQuality also goes by the certificate's own words ("Scan to Verify"). Never raises
  # for an image it can't read: that is "not found".
  class QrFinder
    SCALES = [ 1, 2, 3 ].freeze
    MAX_SIDE = 3_000 # px
    MIN_BAND = 2 # px: a thinner band isn't a printed mark
    TOLERANCE = 0.5 # how far each band may be from its share of the mark
    SAME_MARK = 1.5 # bands of one mark's size apart: across and down meet at the same place
    SAME_CODE = 1.6 # how much two marks' sizes may differ within one code
    SQUARE = 0.15 # how far the mark triangle's two sides may differ from each other
    MIN_MODULES_APART = 14 # the smallest QR code's marks are 14 modules apart
    TEMPLATE_MATCH = 0.9 # the share of a mark's 49 modules that must look right
    THRESHOLD = 128
    NOISE_CELL = 3 # px: a square's contrast is measured in cells this size
    NOISE_MIN_CONTRAST = 20 # standard deviation within a cell
    NOISE_BRIGHTNESS = (60..200) # a cell's mean: not a solid dark logo, not white paper
    NOISE_SIDE = (42..120) # px: a bigger code has marks to find; a bigger block is a photo
    NOISE_SHAPE = (0.75..1.33)
    NOISE_FILL = 0.6
    MARK_SHARES = [ 1, 1, 3, 1, 1 ].freeze
    MARK_BANDS = MARK_SHARES.sum

    Mark = Data.define(:x, :y, :size)

    def initialize(path)
      @path = path.to_s
    end

    def present?
      image = Vips::Image.new_from_file(@path).colourspace(:b_w).extract_band(0)
      scales = SCALES.select { |scale| scale == 1 || [ image.width, image.height ].max * scale <= MAX_SIDE }
      scales.any? { |scale| code?(marks(scale == 1 ? image : image.resize(scale))) } || fine_print_square?(image)
    rescue Vips::Error
      false
    end

    private
      # A roughly square patch of cells with high contrast and a middling mean.
      def fine_print_square?(image)
        gray = image.cast(:float)
        mean = gray.shrink(NOISE_CELL, NOISE_CELL)
        variance = (gray * gray).shrink(NOISE_CELL, NOISE_CELL) - mean * mean
        contrast = (variance > 0).ifthenelse(variance, 0)**0.5
        mask = ((contrast > NOISE_MIN_CONTRAST) & (mean > NOISE_BRIGHTNESS.begin) & (mean < NOISE_BRIGHTNESS.end)).cast(:uchar)
        patches(mask.write_to_memory.bytes, mask.width, mask.height).any? do |width, height, cells|
          [ width, height ].all? { |side| NOISE_SIDE.cover?(side * NOISE_CELL) } && NOISE_SHAPE.cover?(width.fdiv(height)) &&
            cells.fdiv(width * height) >= NOISE_FILL
        end
      end

      # [width, height, cells] of each connected patch of set cells.
      def patches(pixels, width, height)
        seen = Array.new(width * height, false)
        (0...pixels.size).filter_map do |start|
          next if pixels[start].zero? || seen[start]

          seen[start] = true
          stack = [ start ]
          cells = 0
          left = right = start % width
          top = bottom = start / width
          until stack.empty?
            cell = stack.pop
            cells += 1
            row, column = cell.divmod(width)
            left = column if column < left
            right = column if column > right
            bottom = row if row > bottom
            top = row if row < top
            [ (cell - 1 if column.positive?), (cell + 1 if column < width - 1), (cell - width if row.positive?), (cell + width if row < height - 1) ].compact.each do |neighbour|
              next if seen[neighbour] || pixels[neighbour].zero?

              seen[neighbour] = true
              stack << neighbour
            end
          end
          [ right - left + 1, bottom - top + 1, cells ]
        end
      end

      # Marks found both across and down.
      def marks(image)
        dark = (image < THRESHOLD).cast(:uchar)
        across = centers(dark)
        down = centers(dark.rot(:d90)).map { |position, line, size| [ line, image.height - 1 - position, size ] }
        across.filter_map do |x, y, size|
          match = down.find { |a, b, other| (a - x).abs <= size * SAME_MARK && (b - y).abs <= size * SAME_MARK && close?(size, other) }
          Mark.new(x: x, y: y, size: size) if match && looks_like_mark?(dark, x, y, size)
        end.uniq { |mark| [ mark.x / 8, mark.y / 8 ] }
      end

      # [position along the line, line, band size] of each 1:1:3:1:1 run of bands.
      def centers(dark)
        bytes = dark.write_to_memory
        found = []
        dark.height.times do |line|
          row = bytes.byteslice(line * dark.width, dark.width)
          runs = row.scan(/\xFF+|\x00+/n)
          position = 0
          runs.each_with_index do |run, index|
            if run.getbyte(0) == 255 && index + 4 < runs.size
              window = runs[index, 5].map(&:bytesize)
              if mark?(window)
                found << [ position + window.sum / 2, line, window.sum.fdiv(MARK_BANDS) ]
              end
            end
            position += run.bytesize
          end
        end
        found
      end

      def mark?(window)
        size = window.sum.fdiv(MARK_BANDS)
        return false if window.min < MIN_BAND

        window.zip(MARK_SHARES).all? { |band, share| (band - size * share).abs <= size * share * TOLERANCE }
      end

      # A mark is 7 by 7 modules: a dark ring, a light ring, and a dark 3 by 3 centre.
      def looks_like_mark?(dark, x, y, size)
        @pixels = nil if @pixels_of != dark
        @pixels_of = dark
        @pixels ||= dark.write_to_memory
        right = (-3..3).to_a.product((-3..3).to_a).count do |across, down|
          column = (x + across * size).round
          row = (y + down * size).round
          next false unless column.between?(0, dark.width - 1) && row.between?(0, dark.height - 1)

          (@pixels.getbyte(row * dark.width + column) == 255) == ([ across.abs, down.abs ].max != 2)
        end
        right >= 49 * TEMPLATE_MATCH
      end

      # Three marks of about one size forming a right-angled corner, as a code's do.
      def code?(marks)
        marks.combination(3).any? do |trio|
          sizes = trio.map(&:size)
          next false if sizes.max / sizes.min > SAME_CODE

          sides = trio.combination(2).map { |a, b| Math.hypot(a.x - b.x, a.y - b.y) }.sort
          next false if sides.first < sizes.max * MIN_MODULES_APART

          (sides[0] - sides[1]).abs <= sides[1] * SQUARE && (sides[2] - Math.hypot(sides[0], sides[1])).abs <= sides[2] * SQUARE
        end
      end

      def close?(one, other)
        [ one, other ].max / [ one, other ].min <= SAME_CODE
      end
  end
end
