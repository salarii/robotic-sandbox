import cv2
import numpy as np
import os

os.environ["QT_QPA_PLATFORM"] = "xcb"

def main():
    cap = cv2.VideoCapture(2, cv2.CAP_V4L2)
    if not cap.isOpened():
        print("ERROR: Cannot open /dev/video2")
        return

    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    cap.set(cv2.CAP_PROP_FPS, 30)

    # --- Load Haar cascades (built into OpenCV, no download needed) ---
    face_cascade    = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
    eye_cascade     = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_eye.xml')
    body_cascade    = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_fullbody.xml')

    mode = 0
    modes = [
        "0: Raw feed",
        "1: Face + Eye detection",
        "2: Edge detection (Canny)",
        "3: Motion detection",
        "4: Colour tracking (RED)",
    ]

    prev_gray = None
    snapshot_count = 0

    print("Controls:")
    print("  0-4  : switch mode")
    print("  s    : save snapshot")
    print("  q    : quit")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        display = cv2.resize(frame, (1280, 720))
        output  = display.copy()
        gray    = cv2.cvtColor(display, cv2.COLOR_BGR2GRAY)

        # ── Mode 1: Face & eye detection ──────────────────────────────
        if mode == 1:
            faces = face_cascade.detectMultiScale(
                gray, scaleFactor=1.1, minNeighbors=5, minSize=(60, 60))
            for (x, y, w, h) in faces:
                cv2.rectangle(output, (x, y), (x+w, y+h), (0, 255, 0), 2)
                cv2.putText(output, "Face", (x, y-8),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
                # detect eyes only inside face region
                roi_gray = gray[y:y+h, x:x+w]
                roi_color = output[y:y+h, x:x+w]
                eyes = eye_cascade.detectMultiScale(roi_gray, 1.1, 10)
                for (ex, ey, ew, eh) in eyes:
                    cv2.rectangle(roi_color, (ex, ey),
                                  (ex+ew, ey+eh), (255, 0, 0), 2)

        # ── Mode 2: Canny edge detection ──────────────────────────────
        elif mode == 2:
            blurred = cv2.GaussianBlur(gray, (5, 5), 0)
            edges   = cv2.Canny(blurred, threshold1=50, threshold2=150)
            output  = cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)

        # ── Mode 3: Motion detection ───────────────────────────────────
        elif mode == 3:
            if prev_gray is not None:
                diff    = cv2.absdiff(prev_gray, gray)
                _, thresh = cv2.threshold(diff, 25, 255, cv2.THRESH_BINARY)
                thresh  = cv2.dilate(thresh, None, iterations=2)
                contours, _ = cv2.findContours(
                    thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                motion_detected = False
                for cnt in contours:
                    if cv2.contourArea(cnt) > 1500:   # ignore tiny noise
                        x, y, w, h = cv2.boundingRect(cnt)
                        cv2.rectangle(output, (x, y), (x+w, y+h), (0, 0, 255), 2)
                        motion_detected = True
                if motion_detected:
                    cv2.putText(output, "MOTION DETECTED", (20, 50),
                                cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0, 0, 255), 3)
            prev_gray = gray.copy()

        # ── Mode 4: Red colour tracking ───────────────────────────────
        elif mode == 4:
            hsv = cv2.cvtColor(display, cv2.COLOR_BGR2HSV)
            # red wraps around in HSV so we need two ranges
            mask1 = cv2.inRange(hsv, np.array([0,  120, 70]),
                                     np.array([10, 255, 255]))
            mask2 = cv2.inRange(hsv, np.array([170, 120, 70]),
                                     np.array([180, 255, 255]))
            mask  = cv2.bitwise_or(mask1, mask2)
            mask  = cv2.erode(mask,  None, iterations=2)
            mask  = cv2.dilate(mask, None, iterations=2)
            contours, _ = cv2.findContours(
                mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if contours:
                c = max(contours, key=cv2.contourArea)
                if cv2.contourArea(c) > 500:
                    (cx, cy), radius = cv2.minEnclosingCircle(c)
                    cv2.circle(output, (int(cx), int(cy)),
                               int(radius), (0, 0, 255), 3)
                    cv2.putText(output, f"RED object r={int(radius)}px",
                                (int(cx)-60, int(cy)-int(radius)-10),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

        # ── HUD overlay (always shown) ────────────────────────────────
        cv2.putText(output, modes[mode], (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
        cv2.putText(output, "Keys: 0-4 modes | s=snapshot | q=quit",
                    (10, output.shape[0] - 10),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

        cv2.imshow('SUFCO SU200-MB', output)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('s'):
            fname = f"snapshot_{snapshot_count:03d}.jpg"
            cv2.imwrite(fname, frame)   # saves FULL 1080p resolution
            print(f"Saved {fname}")
            snapshot_count += 1
        elif ord('0') <= key <= ord('4'):
            mode = key - ord('0')
            print(f"Switched to {modes[mode]}")

    cap.release()
    cv2.destroyAllWindows()

if __name__ == '__main__':
    main()