module EasyFfmpeg
  module Vr360
    # Stitch is a high-bitrate intermediate; Encode skips the v360 filter.
    enum Mode
      Full
      Stitch
      Encode
    end

    enum Input
      Dfisheye
      Fisheye
    end

    DEFAULT_FOV = 195

    def self.parse_mode?(value : String) : Mode?
      case value.downcase
      when "full"   then Mode::Full
      when "stitch" then Mode::Stitch
      when "encode" then Mode::Encode
      else               nil
      end
    end

    def self.parse_input?(value : String) : Input?
      case value.downcase
      when "dfisheye", "dual"   then Input::Dfisheye
      when "fisheye", "single"  then Input::Fisheye
      else                            nil
      end
    end

    # 50 Mbps at 4K matches PowerDirector's high-quality 360 export.
    def self.bitrate_mbps(width : Int32, mode : Mode) : Int32
      base = case
             when width >= 3840 then 50
             when width >= 2048 then 25
             else                    12
             end
      mode.stitch? ? base * 2 : base
    end

    def self.dewarp_filter(input : Input, fov : Int32 = DEFAULT_FOV) : String
      kind = input.dfisheye? ? "dfisheye" : "fisheye"
      "v360=input=#{kind}:output=equirect:ih_fov=#{fov}:iv_fov=#{fov}"
    end

    def self.encoder_args(mbps : Int32) : Array(String)
      maxrate = (mbps * 1.2).to_i
      bufsize = mbps * 2
      ["-rc", "vbr",
       "-b:v", "#{mbps}M",
       "-maxrate", "#{maxrate}M",
       "-bufsize", "#{bufsize}M",
       "-preset", "p5",
       "-tune", "hq",
       "-profile:v", "high"]
    end
  end
end
