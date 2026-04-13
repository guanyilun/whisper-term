from whisper_term.transcriber import Segment


def format_time(seconds: float) -> str:
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def format_segments(segments: list[Segment], timestamps: bool = False) -> str:
    lines = []
    for seg in segments:
        if timestamps:
            start = format_time(seg.start)
            end = format_time(seg.end)
            lines.append(f"[{start} --> {end}]  {seg.text}")
        else:
            lines.append(seg.text)
    return "\n".join(lines)
