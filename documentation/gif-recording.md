# GIF recording

Press **F5** in an Ellipse GPU game to begin recording; press **F5** again
to save a looping GIF in `recordings/clip-<timestamp>.gif` relative to the
working directory. The console reports recording, encoding, and the saved path.
`ffmpeg` must be available on PATH. A missing encoder leaves the game running.

Capture runs at 20 fps (50 ms timing precision). The worker retains a rolling
400-frame / 20-second buffer. Short clips contain the interval between presses;
longer recordings export the latest 20 seconds. Recording consumes no capture
resources while idle. The GPU target is reused after the first recording.

Frames fit within 640×360 with linear GPU scaling. Resizing during recording
preserves aspect with black bars. Capture adds a scaled texture copy/download
at most every 50 ms; collection follows the engine's existing frame fence,
without an extra synchronous GPU wait. A queue of three frames bounds transport
memory and drops captures instead of waiting on the encoder. Missing frames
repeat the previous picture, preserving real playback time.

A worker owns the circular buffer (at most approximately 352 MiB of RGBA data
at 640×360), writes its raw stream to a temporary file on stop, and runs two
FFmpeg passes for an optimized 256-color palette with stable Bayer dithering.
Encoding uses one filter thread and retries smaller dimensions if the result
exceeds 14 MiB. Temporary files are removed after encoding. Export needs up to
352 MiB of temporary disk space. Quality and file size depend on the scene.

F5 is debounced: holding it does not toggle repeatedly. Another recording can
start after the current export finishes. Exiting saves an active clip and waits
for the worker, so quit can take longer while encoding. Capture currently
covers the GPU frame presentation path (including attached games), rather than
the separate terminal/Clay UI renderer. Existing attached-mode readback costs
remain in that mode.

Run `nim c -r --threads:on --mm:atomicArc tests/gifrecorder_test.nim` to verify
ring ordering, overflow, dropped-frame timing, and a decoded 400-frame GIF.
This test also needs `ffprobe` on PATH.
