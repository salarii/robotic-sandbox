import cv2

def main():
    # /dev/video2 = index 2, force V4L2 backend
    cap = cv2.VideoCapture(2, cv2.CAP_V4L2)

    if not cap.isOpened():
        print("ERROR: Cannot open /dev/video2")
        return

    # MJPEG = full 4MP at 30fps over USB 2.0
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  2560)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1440)
    cap.set(cv2.CAP_PROP_FPS, 30)

    actual_w = cap.get(cv2.CAP_PROP_FRAME_WIDTH)
    actual_h = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    actual_fps = cap.get(cv2.CAP_PROP_FPS)
    print(f"Stream: {actual_w}x{actual_h} @ {actual_fps}fps")

    while True:
        ret, frame = cap.read()
        if not ret:
            print("Failed to grab frame")
            break

        # Downscale for display only (2560x1440 is huge on screen)
        display = cv2.resize(frame, (1280, 720))
        cv2.imshow('SUFCO SU200-MB - press Q to quit', display)

        # Save full-res snapshot with 's'
        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('s'):
            cv2.imwrite('snapshot.jpg', frame)
            print("Saved snapshot.jpg")

    cap.release()
    cv2.destroyAllWindows()

if __name__ == '__main__':
    main()