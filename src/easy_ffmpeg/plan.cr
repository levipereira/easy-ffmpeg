module EasyFfmpeg
  SCALE_HEIGHTS = {
    "4k" => 2160, "2k" => 1440, "fullhd" => 1080, "hd" => 720, "retro" => 480, "icon" => 240,
    "2160p" => 2160, "1440p" => 1440, "1080p" => 1080, "720p" => 720, "480p" => 480,
  }
  ASPECT_RATIOS  = {"wide" => {16, 9}, "4:3" => {4, 3}, "8:7" => {8, 7}, "square" => {1, 1}, "tiktok" => {9, 16}}

  enum StreamAction
    Copy
    Transcode
    Drop
  end

  struct StreamPlan
    getter stream : StreamInfo
    getter action : StreamAction
    getter encoder : String?
    getter encoder_args : Array(String)
    getter reason : String
    getter output_codec_display : String

    def initialize(@stream, @action, @encoder = nil, @encoder_args = [] of String,
                   @reason = "", @output_codec_display = "")
    end
  end

  class ConversionPlan
    getter input : MediaInfo
    getter output_path : String
    getter target_format : String
    getter preset : Preset
    getter stream_plans : Array(StreamPlan)
    getter global_args : Array(String)
    getter video_filters : Array(String)
    getter is_remux_only : Bool
    getter start_time : Float64?
    getter end_time : Float64?
    getter duration : Float64?
    getter scale : String?
    getter aspect : String?
    getter crop : Bool
    getter overwrite_output : Bool
    getter use_gpu : Bool
    getter gpu_quality : GpuSupport::Quality
    getter vr360_mode : Vr360::Mode?
    getter vr360_input : Vr360::Input
    getter vr360_profile : Vr360::Profile
    getter vr360_fov : Int32?
    getter vr360_yaw : Float64
    getter vr360_pitch : Float64
    getter vr360_roll : Float64
    getter? pure_gpu_pipeline : Bool

    def initialize(@input, @output_path, @target_format, @preset,
                   @start_time = nil, @end_time = nil, @duration = nil,
                   @scale = nil, @aspect = nil, @crop = false,
                   @overwrite_output = false, @use_gpu = false,
                   @gpu_quality = GpuSupport::Quality::Balanced,
                   @vr360_mode = nil, @vr360_input = Vr360::Input::Dfisheye,
                   @vr360_profile = Vr360::Profile::Generic, @vr360_fov = nil,
                   @vr360_yaw = 0.0, @vr360_pitch = 0.0, @vr360_roll = 0.0)
      @stream_plans = [] of StreamPlan
      @global_args = [] of String
      @video_filters = [] of String
      @is_remux_only = false
      @pure_gpu_pipeline = false
      build
    end

    # Effective duration of output (accounting for trim)
    def effective_duration : Float64
      total = input.format.duration
      ss = start_time || 0.0
      if d = duration
        d
      elsif et = end_time
        et - ss
      else
        total - ss
      end
    end

    def mapped_streams : Array(StreamPlan)
      stream_plans.reject(&.action.drop?)
    end

    def video_plans : Array(StreamPlan)
      stream_plans.select { |p| p.stream.video? }
    end

    def audio_plans : Array(StreamPlan)
      stream_plans.select { |p| p.stream.audio? }
    end

    def sub_plans : Array(StreamPlan)
      stream_plans.select { |p| p.stream.subtitle? }
    end

    private def build
      config = PresetConfig.for(preset, target_format)

      plan_video_streams(config)
      plan_audio_streams(config)
      plan_subtitle_streams(config)
      plan_other_streams

      if config.faststart
        @global_args << "-movflags" << "+faststart"
      end

      @is_remux_only = stream_plans.all? { |p| p.action.copy? || p.action.drop? }
      @pure_gpu_pipeline = compute_pure_gpu_pipeline
      rewrite_filters_for_cuda if @pure_gpu_pipeline
    end

    # True when frames can stay on the GPU from decode to encode:
    #   - --gpu was requested
    #   - at least one video stream is being transcoded, and every transcoded
    #     video stream goes through an NVENC encoder
    #   - no aspect filter is requested (crop/pad have no native CUDA filter
    #     in our build; using them forces the bounce CPU↔GPU)
    private def compute_pure_gpu_pipeline : Bool
      return false unless use_gpu
      return false unless aspect.nil?
      return false if @video_filters.any?(&.starts_with?("v360="))
      transcodes = stream_plans.select { |p| p.stream.video? && p.action.transcode? }
      return false if transcodes.empty?
      transcodes.all? { |p| p.encoder.try(&.ends_with?("_nvenc")) || false }
    end

    # In pure GPU mode the decoder hands us CUDA surfaces; CPU-side filters
    # like `scale` and `format` would force a round-trip through system
    # memory. Translate them to their CUDA equivalents (or drop them when
    # NVENC handles the work natively).
    private def rewrite_filters_for_cuda
      @video_filters = @video_filters.compact_map do |filter|
        case
        when filter.starts_with?("scale=")
          filter.sub("scale=", "scale_cuda=")
        when filter.starts_with?("yadif=") || filter == "yadif"
          # yadif_cuda accepts the same mode/parity/deint syntax as yadif.
          filter.sub("yadif", "yadif_cuda")
        when filter == "format=yuv420p"
          # NVENC will emit yuv420p (8-bit) by default for h264_nvenc and
          # hevc_nvenc, so we can drop the explicit format conversion.
          nil
        else
          filter
        end
      end
    end

    private def plan_video_streams(config : PresetConfig)
      needs_filters = !scale.nil? || !aspect.nil? || !vr360_mode.nil?
      input.video_streams.each do |stream|
        if config.force_transcode || needs_filters
          plan_video_transcode(stream, config)
        elsif CodecSupport.video_compatible?(stream.codec_name, target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "compatible",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        else
          plan_video_transcode(stream, config)
        end
      end
    end

    private def plan_video_transcode(stream : StreamInfo, config : PresetConfig)
      cpu_encoder = config.video_codec || CodecSupport::DEFAULT_VIDEO_CODEC[target_format]? || "libx264"

      # GPU swap: replace cpu encoder with NVENC equivalent when available.
      # Codecs without NVENC equivalents (e.g. libvpx-vp9) silently fall back to CPU.
      encoder = (use_gpu ? GpuSupport.gpu_encoder_for?(cpu_encoder) : nil) || cpu_encoder

      # vr360 overrides the preset's encoder and args — bitrate is sized to
      # the *input* width so --scale downsamples without dropping quality.
      if mode = vr360_mode
        encoder = "h264_nvenc"
        width = stream.width || 3840
        args = Vr360.encoder_args(Vr360.bitrate_mbps(width, mode))
        append_vr360_filters(stream, mode)
        append_vr360_scale(stream)
        record_video_transcode(stream, encoder, args, mode.to_s.downcase)
        return
      end

      base_args = if config.force_transcode
                    config.video_args.dup
                  else
                    default_quality_args(cpu_encoder)
                  end

      args = if encoder != cpu_encoder
               base_args.empty? ? GpuSupport.default_quality_args(encoder, gpu_quality) : GpuSupport.translate_args(base_args, gpu_quality)
             else
               base_args
             end

      # HDR preservation: when the source carries PQ/HLG transfer metadata
      # and we're encoding through hevc_nvenc (the only NVENC encoder with
      # solid HDR support), propagate the color metadata so the output is
      # tagged correctly. The 10-bit bit depth is inherited automatically
      # from the input surface — hevc_nvenc picks Main 10 profile when fed
      # 10-bit frames, so setting -pix_fmt explicitly would conflict with
      # CUDA hwaccel surfaces.
      preserve_hdr = stream.hdr? && encoder == "hevc_nvenc"
      if preserve_hdr
        args << "-color_primaries" << (stream.color_primaries || "bt2020")
        args << "-color_trc" << (stream.color_transfer || "smpte2084")
        args << "-colorspace" << (stream.color_space || "bt2020nc")
        args << "-color_range" << (stream.color_range || "tv")
      end

      # 0. Deinterlace (must come first so downstream filters see progressive
      # frames). yadif here gets rewritten to yadif_cuda later when the pure
      # GPU pipeline is engaged.
      if stream.interlaced?
        @video_filters << "yadif=0:-1:0"
      end

      # 1. Scale filter (--scale overrides preset max_height)
      if s = scale
        target_h = SCALE_HEIGHTS[s]
        if h = stream.height
          if h > target_h
            @video_filters << "scale=-2:#{target_h}"
          end
        end
      elsif max_h = config.max_height
        if h = stream.height
          if h > max_h
            @video_filters << "scale=-2:#{max_h}"
          end
        end
      end

      # 2. Ensure even dimensions for h264/h265 (required by libx264/libx265 and
      # their NVENC equivalents)
      if %w[libx264 libx265 h264_nvenc hevc_nvenc].includes?(encoder)
        if @video_filters.none? { |f| f.starts_with?("scale=") }
          w = stream.width
          h = stream.height
          if w && h && (w.odd? || h.odd?)
            @video_filters << "scale=trunc(iw/2)*2:trunc(ih/2)*2"
          end
        end

        # Pixel format. Skip when preserving HDR — we encode straight to
        # p010le (10-bit) and forcing yuv420p would throw away the bit depth.
        unless preserve_hdr
          pix = stream.pix_fmt
          if pix && !%w[yuv420p yuv420p10le].includes?(pix)
            @video_filters << "format=yuv420p"
          end
        end
      end

      # 3. Aspect ratio filter
      if a = aspect
        num, den = ASPECT_RATIOS[a]
        if crop
          @video_filters << "crop=min(iw\\,ih*#{num}/#{den}):min(ih\\,iw*#{den}/#{num})"
        else
          @video_filters << "pad=max(iw\\,ih*#{num}/#{den}):max(ih\\,iw*#{den}/#{num}):(ow-iw)/2:(oh-ih)/2:black"
        end
      end

      reason = if !scale.nil? || !aspect.nil?
                 parts = [] of String
                 parts << "--scale #{scale}" if scale
                 parts << "--aspect #{aspect}" if aspect
                 parts.join(" ")
               elsif config.force_transcode
                 preset.to_s.downcase
               else
                 "incompatible"
               end

      @stream_plans << StreamPlan.new(
        stream: stream,
        action: StreamAction::Transcode,
        encoder: encoder,
        encoder_args: args,
        reason: reason,
        output_codec_display: CodecSupport.codec_display_name(encoder),
      )
    end

    # v360 is CPU-only; its presence is what disables the pure GPU pipeline.
    private def append_vr360_filters(stream : StreamInfo, mode : Vr360::Mode)
      return if mode.encode?
      fov = vr360_fov || Vr360.profile_fov(vr360_profile)
      @video_filters << Vr360.dewarp_filter(vr360_input, fov,
        yaw: vr360_yaw, pitch: vr360_pitch, roll: vr360_roll)
    end

    private def append_vr360_scale(stream : StreamInfo)
      return unless s = scale
      target_h = SCALE_HEIGHTS[s]
      if h = stream.height
        @video_filters << "scale=-2:#{target_h}" if h > target_h
      end
    end

    private def record_video_transcode(stream : StreamInfo, encoder : String,
                                       args : Array(String), reason : String)
      @stream_plans << StreamPlan.new(
        stream: stream,
        action: StreamAction::Transcode,
        encoder: encoder,
        encoder_args: args,
        reason: "vr360 #{reason}",
        output_codec_display: CodecSupport.codec_display_name(encoder),
      )
    end

    private def plan_audio_streams(config : PresetConfig)
      input.audio_streams.each do |stream|
        if config.force_transcode
          plan_audio_transcode(stream, config)
        elsif CodecSupport.audio_compatible?(stream.codec_name, target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "compatible",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        else
          plan_audio_transcode(stream, config)
        end
      end
    end

    private def plan_audio_transcode(stream : StreamInfo, config : PresetConfig)
      encoder = config.audio_codec || CodecSupport::DEFAULT_AUDIO_CODEC[target_format]? || "aac"
      args = config.force_transcode ? config.audio_args.dup : default_audio_args(encoder)

      if config.downmix_stereo
        channels = stream.channels
        if channels && channels > 2
          args << "-ac" << "2"
        end
      end

      reason = config.force_transcode ? preset.to_s.downcase : "incompatible"

      @stream_plans << StreamPlan.new(
        stream: stream,
        action: StreamAction::Transcode,
        encoder: encoder,
        encoder_args: args,
        reason: reason,
        output_codec_display: CodecSupport.codec_display_name(encoder),
      )
    end

    private def plan_subtitle_streams(config : PresetConfig)
      if config.drop_subs
        input.subtitle_streams.each do |stream|
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Drop,
            reason: "#{preset.to_s.downcase} preset",
            output_codec_display: "",
          )
        end
        return
      end

      target_sub = CodecSupport::DEFAULT_SUB_CODEC[target_format]?

      input.subtitle_streams.each do |stream|
        if CodecSupport.sub_compatible?(stream.codec_name, target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "compatible",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        elsif target_sub && CodecSupport.text_sub?(stream.codec_name)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Transcode,
            encoder: target_sub,
            reason: "convert",
            output_codec_display: CodecSupport.codec_display_name(target_sub),
          )
        else
          reason = CodecSupport::CONTAINER_SUB_CODECS[target_format]?.try(&.empty?) ? "unsupported container" : "bitmap subtitle"
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Drop,
            reason: reason,
            output_codec_display: "",
          )
        end
      end
    end

    private def plan_other_streams
      input.other_streams.each do |stream|
        if stream.is_attached_pic && %w[mp4 mov matroska].includes?(target_format)
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Copy,
            encoder: "copy",
            reason: "cover art",
            output_codec_display: CodecSupport.codec_display_name(stream.codec_name),
          )
        else
          @stream_plans << StreamPlan.new(
            stream: stream,
            action: StreamAction::Drop,
            reason: "unsupported auxiliary stream",
            output_codec_display: "",
          )
        end
      end
    end

    private def default_quality_args(encoder : String) : Array(String)
      case encoder
      when "libx264"  then ["-crf", "18", "-preset", "medium"]
      when "libx265"  then ["-crf", "20", "-preset", "medium"]
      when "libvpx-vp9" then ["-crf", "24", "-b:v", "0"]
      when "libsvtav1" then ["-crf", "23", "-preset", "6"]
      else                  [] of String
      end
    end

    private def default_audio_args(encoder : String) : Array(String)
      case encoder
      when "aac"        then ["-b:a", "320k"]
      when "libmp3lame" then ["-b:a", "320k"]
      when "libopus"    then ["-b:a", "256k"]
      when "libvorbis"  then ["-b:a", "256k"]
      when "flac"       then [] of String
      else                   [] of String
      end
    end
  end
end
