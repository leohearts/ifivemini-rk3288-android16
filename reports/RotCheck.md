# RotCheck: panel vs screencap across user_rotation 0-3, plus video

Sources: runs/soak2/ (rotcheck.sh, cam-*.jpg, sc-*.png, rot*.txt, video.txt)
Measured: PIL grayscale mean/std. Panel = webcam crop x725-1365, y565-1080.

| case | SF transform | screencap size, mean/std | panel mean/std |
|---|---|---|---|
| rot0 | ROT_0 | 1536x2048, 54.7/71.0 | 164.1/40.1 |
| rot1 | ROT_90 | 2048x1536, 33.6/44.4 | 152.2/37.1 |
| rot2 | ROT_180 | 1536x2048, 54.7/71.0 | 144.9/35.3 |
| rot3 | ROT_270 | 2048x1536, 33.6/44.4 | 137.8/35.1 |
| video | n/a | 1536x2048, 0.0/0.0 (ALL BLACK) | 119.9/28.3 |

- Not black on the panel at any rotation. Screencap is not black at rot0-3 in this run.
- Screencap rot1 is NOT black in this run, which contradicts the earlier all-black rot1 report. Repeat once to check if it is intermittent.
- Video: screencap is all black, but the panel shows content (mean 120). Screencap of video is black; the panel is not.
- HWC logs: no "fallback"/GLES line. Repeated benign lines: getLuts UNSUPPORTED, SetColorTransform unsupported, setPowerMode BAD_DISPLAY on screen off/on, RotationLayer "Invalid device requested composition type change".
- NOT verified: that the panel shows correctly rotated UI. Means alone do not show orientation. The cam images were not inspected visually.
- Verdict: no evidence of a broken HWC2 rotation path. Panel is lit at all rotations. Rotation correctness still needs a visual check of cam-rot1 and cam-rot3.
