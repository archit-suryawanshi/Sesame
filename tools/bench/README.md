# Embedding bench

Measures the genuine/impostor similarity split of the app's real detect -> align -> embed path, so
the constants in `FaceMatchCalibration` come from measurements instead of intuition.

## Images

`pairs.txt` names images from [deepface](https://github.com/serengil/deepface)'s unit test set,
whose ground truth comes from `tests/unit/test_verify.py` in that repo:

```bash
for n in 1 2 3 5 6 7 8 9 11; do
  curl -sSLO "https://raw.githubusercontent.com/serengil/deepface/master/tests/unit/dataset/img${n}.jpg"
done
```

deepface asserts img1~img2, img5~img6, img6~img7, img8~img9, img1~img11, img2~img11, and that
img1/img3, img2/img3, img6/img8, img6/img9 differ. It never claims img1 and img6 are different
people, and measured similarity says they are the same person, so images 1, 2, 5, 6, 7 and 11 form
one identity, 8 and 9 a second, and 3 a third.

## Run

```bash
swiftc -O -o /tmp/embedding_bench \
  tools/embedding_bench.swift \
  Sesame/FaceDetector.swift Sesame/FaceAligner.swift Sesame/FaceEmbedder.swift \
  Sesame/ArcFaceEmbedder.swift Sesame/Liveness/LandmarkGeometry.swift \
  Sesame/Liveness/LivenessCues.swift Sesame/Liveness/LivenessScoring.swift \
  Sesame/Liveness/GeometryLiveness.swift Sesame/Liveness/GlareCue.swift

/tmp/embedding_bench \
  "$(find ~/Library/Developer/Xcode/DerivedData -name ArcFace.mlmodelc -path "*Sesame*" | head -1)" \
  <image-dir> tools/bench/pairs.txt
```

## Result on that set

| measure | genuine | impostor |
|---|---|---|
| pairwise cosine | 0.570 to 0.818 | -0.072 to 0.016 |
| gallery top-3 mean | 0.611 to 0.793 | -0.064 to 0.083 |
| gallery centroid | 0.659 to 0.871 | -0.071 to 0.091 |

The two populations are separated by roughly half the scale, which is what justifies putting the
cutoff in the middle of the gap rather than at the top edge of the genuine range. Upstream's 0.66
rejected one genuine probe in six on studio-quality portraits, before any webcam degradation.
