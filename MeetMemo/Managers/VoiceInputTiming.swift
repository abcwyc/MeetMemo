import Foundation

/// 语音输入相关的计时/缓冲常量集中处，每项附调参依据，便于后续统一调整。
enum VoiceInputTiming {
    /// 停止后等待 provider flush 出尾部 final 的最长时间。
    /// 取 2.2s：覆盖 SenseVoice 离线尾段解码，又不至于让用户停止后明显卡顿。
    static let finalFlushTimeout: TimeInterval = 2.2

    /// finalization 完成后再多等一拍，给最后一个 onTranscriptUpdate 回调落地的时间。
    static let postFinalizationDrainDelay: Duration = .milliseconds(120)

    /// 停止时补发的尾部静音时长，促使 VAD/解码器吐出最后一段。
    /// 1/3 秒经验值：足够触发尾段切分，又不会明显拉长结束延迟。
    static let trailingSilenceDuration: TimeInterval = 1.0 / 3.0

    /// provider 连接（含首次模型加载）期间最多缓冲多少秒麦克风音频（环形缓冲），
    /// 防止冷启动吃掉开头几秒。12s 覆盖常见的本地模型冷加载耗时。
    static let maxPendingAudioDuration: TimeInterval = 12

    /// 单击/双击模式下，一次「干净轻拍」允许的最长按下时长，超过则视为长按而非轻拍。
    static let cleanTapMaxDuration: TimeInterval = 0.6

    /// 双击触发时，两次激活之间允许的最大间隔。
    static let doublePressWindow: TimeInterval = 0.45

    /// listening 安全阀：超过则自动停止并插入已识别内容，
    /// 避免单击/双击启动后忘记停止、或按住模式 keyUp 丢失导致的无限录音。
    static let maxListeningDuration: TimeInterval = 90

    /// 语音输入音频采样参数：16kHz / 16-bit 单声道（与 STT provider 输入一致）。
    static let audioBytesPerSecond = 16_000 * 2

    static var maxPendingAudioBytes: Int {
        Int(Double(audioBytesPerSecond) * maxPendingAudioDuration)
    }

    static var trailingSilenceBytes: Int {
        Int(Double(audioBytesPerSecond) * trailingSilenceDuration)
    }
}
