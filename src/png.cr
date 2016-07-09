require "./rgba"
require "./canvas"
require "./utils"
require "./datastream"
require "./filters"
require "./color_types"

module StumpyPNG
  class PNG
    # { name, valid bit depths, "fields" per pixel }
    COLOR_TYPES = {
      0 => { ColorTypes::Grayscale, [1, 2, 4, 8, 16], 1 },
      2 => { ColorTypes::RGB, [8, 16], 3 },
      3 => { ColorTypes::Palette, [1, 2, 4, 8], 1 },
      4 => { ColorTypes::GrayscaleAlpha, [8, 16], 2 },
      6 => { ColorTypes::RGBAlpha, [8, 16], 4 },
    }

    INTERLACE_METHODS = {
      0 => :no_interlace,
      1 => :adam7,
    }

    FILTERS = {
      0 => Filters::None,
      1 => Filters::Sub,
      2 => Filters::Up,
      3 => Filters::Average,
      4 => Filters::Paeth,
    }

    getter width : Int32, height : Int32
    getter bit_depth, color_type, compression_method, filter_method, interlace_method, palette
    getter parsed, data
    getter canvas : Canvas

    def initialize
      @width = 0
      @height = 0

      @bit_depth = 0_u8
      @color_type = 0_u8

      @compression_method = 0_u8
      @filter_method = 0_u8
      @interlace_method = 0_u8

      @palette = [] of RGBA
      @idat_buffer = MemoryIO.new
      @parsed = false

      @data = [] of UInt8

      @idat_count = 0

      @canvas = Canvas.new(0, 0)
    end

    def parse_IEND(chunk)
      raise "Missing IDAT chunk" if @idat_count == 0

      # Reset buffer position
      @idat_buffer.pos = 0

      contents = Zlib::Inflate.new(@idat_buffer) do |inflate|
        inflate.gets_to_end
      end
      @data = contents.bytes

      parsed = true

      if @interlace_method == 0
        @canvas = to_canvas_none
      else
        @canvas = to_canvas_adam7
      end
    end

    def parse_IDAT(chunk)
      @idat_count += 1
      # Add chunk data to buffer
      chunk.each do |byte|
        @idat_buffer.write_byte(byte)
      end
    end

    def parse_PLTE(chunk)
      "Invalid palette length" unless (chunk.size % 3) == 0
      @palette = chunk.each_slice(3).map { |rgb| RGBA.from_rgb_n(rgb, 8) }.to_a
    end

    def parse_IHDR(chunk)
      @width              = Utils.parse_integer(chunk.shift(4))
      @height             = Utils.parse_integer(chunk.shift(4))

      @bit_depth          = chunk.shift(1).first
      @color_type         = chunk.shift(1).first
      raise "Invalid color type" unless COLOR_TYPES.has_key?(@color_type)
      unless COLOR_TYPES[@color_type][1].includes?(@bit_depth)
        raise "Invalid bit depth for this color type" 
      end

      @compression_method = chunk.shift(1).first
      raise "Invalid compression method" unless compression_method == 0

      @filter_method      = chunk.shift(1).first
      raise "Invalid filter method" unless filter_method == 0

      @interlace_method   = chunk.shift(1).first
      unless INTERLACE_METHODS.has_key?(interlace_method)
        raise "Invalid interlace method" 
      end
    end

    def to_canvas_none
      canvas = Canvas.new(@width, @height)
      bpp = ([8, @bit_depth].max / 8 * COLOR_TYPES[@color_type][2]).to_i32
      scanline_width = (@bit_depth.to_f / 8 * COLOR_TYPES[@color_type][2] * @width).ceil.to_i32
      prior_scanline = [] of UInt8

      @height.times do |y|
        filter = @data.shift(1).first
        scanline = @data.shift(scanline_width)
        decoded = [] of UInt8

        raise "Unknown filter type #{filter}" unless FILTERS.has_key?(filter)
        decoded = FILTERS[filter].apply(scanline, prior_scanline, bpp)

        prior_scanline = decoded

        x = 0
        COLOR_TYPES[@color_type][0].each_pixel(decoded, @bit_depth, @palette) do |pixel|
          canvas.set_pixel(x, y, pixel)
          x += 1
          break if x >= @width
        end
      end

      canvas
    end

    def to_canvas_adam7
      starting_row  = [0, 0, 4, 0, 2, 0, 1]
      starting_col  = [0, 4, 0, 2, 0, 1, 0]
      row_increment = [8, 8, 8, 4, 4, 2, 2]
      col_increment = [8, 8, 4, 4, 2, 2, 1]

      pass = 0
      row = 0
      col = 0

      canvas = Canvas.new(@width, @height)
      bpp = ([8, @bit_depth].max / 8 * COLOR_TYPES[@color_type][2]).to_i32

      while pass < 7
        prior_scanline = [] of UInt8
        row = starting_row[pass]

        scanline_width_ = [0, ((@width - starting_col[pass]).to_f / col_increment[pass]).ceil].max
        scanline_width = (@bit_depth.to_f / 8 * COLOR_TYPES[@color_type][2] * scanline_width_).ceil.to_i32

        if scanline_width_ == 0
          pass += 1
          next
        end


        while row < @height
          filter = @data.shift(1).first
          scanline = @data.shift(scanline_width)

          raise "Unknown filter type #{filter}" unless FILTERS.has_key?(filter)
          decoded = FILTERS[filter].apply(scanline, prior_scanline, bpp)

          prior_scanline = decoded

          buffer = [] of RGBA
          
          COLOR_TYPES[@color_type][0].each_pixel(decoded, @bit_depth, @palette) do |pixel|
            buffer << pixel
          end

          col = starting_col[pass]
          while col < @width
            canvas.set_pixel(col, row, buffer.shift)
            col += col_increment[pass]
          end
          row += row_increment[pass]
        end
        pass += 1
      end

      canvas
    end

    def parse_chunk(chunk)
      case chunk.type
      when "IHDR"
        parse_IHDR(chunk.data)
      when "PLTE"
        parse_PLTE(chunk.data)
      when "IDAT"
        parse_IDAT(chunk.data)
      when "IEND"
        parse_IEND(chunk.data)
      end
    end
 end
end
