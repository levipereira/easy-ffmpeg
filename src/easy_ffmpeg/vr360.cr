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

    # Profile bundles camera-specific stitching defaults. Explicit flags
    # (--vr360-fov etc.) always win over profile defaults.
    enum Profile
      Generic
      Gear360
    end

    DEFAULT_FOV    = 195
    DEFAULT_INTERP = "lanczos"

    # Empirical FOV from the Samsung Research stitching paper (Ho & Budagavi,
    # ICASSP 2017): 193° gives a noticeably better seam on Gear 360 than the
    # documented 195°.
    GEAR360_FOV = 193

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

    def self.parse_profile?(value : String) : Profile?
      case value.downcase
      when "generic"          then Profile::Generic
      when "gear360", "samsung" then Profile::Gear360
      else                         nil
      end
    end

    # FOV the profile prefers when the user didn't ask for one explicitly.
    def self.profile_fov(profile : Profile) : Int32
      profile.gear360? ? GEAR360_FOV : DEFAULT_FOV
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

    def self.dewarp_filter(input : Input,
                           fov : Int32 = DEFAULT_FOV,
                           yaw : Float64 = 0.0,
                           pitch : Float64 = 0.0,
                           roll : Float64 = 0.0,
                           interp : String = DEFAULT_INTERP) : String
      kind = input.dfisheye? ? "dfisheye" : "fisheye"
      parts = ["input=#{kind}",
               "output=equirect",
               "ih_fov=#{fov}",
               "iv_fov=#{fov}",
               "interp=#{interp}"]
      parts << "yaw=#{format_angle(yaw)}"     unless yaw == 0.0
      parts << "pitch=#{format_angle(pitch)}" unless pitch == 0.0
      parts << "roll=#{format_angle(roll)}"   unless roll == 0.0
      "v360=" + parts.join(":")
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

    # Format as an integer when there's no fractional part; lets specs match
    # "yaw=2" instead of forcing "yaw=2.0" in the emitted filter string.
    private def self.format_angle(v : Float64) : String
      v == v.to_i ? v.to_i.to_s : v.to_s
    end
  end
end
