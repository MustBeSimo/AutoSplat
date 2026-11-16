# Third-party notices

AutoSplat is built on the work listed below. Each component keeps its own licence.

## SHARP model (Apple). Research use only

- **What:** *Sharp Monocular View Synthesis in Less Than a Second*, Mescheder et al., Apple, [arXiv:2512.10685](https://arxiv.org/abs/2512.10685). SHARP predicts a 3D Gaussian representation of a scene directly from a single photograph. It does all of AutoSplat's 3D generation.
- **Licence:** Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement. Full text: [`licenses/APPLE_ML_RESEARCH_MODEL_LICENSE.txt`](licenses/APPLE_ML_RESEARCH_MODEL_LICENSE.txt), also at [apple/ml-sharp](https://github.com/apple/ml-sharp).
- **Research use only:** the licence restricts the model to non-commercial scientific research. It excludes commercial exploitation, product development and use in any commercial product or service.
- **How AutoSplat uses it:** AutoSplat does not ship the model. When you click **Download Model**, it fetches the community Core ML conversion below from Hugging Face and runs inference locally on your Mac. AutoSplat does not modify, retrain or fine-tune the model. It displays the predicted Gaussians, and its OBJ, USDZ and PLY exports reduce them to coloured point clouds.
- **No endorsement:** AutoSplat is an independent project. It is not affiliated with or endorsed by Apple.

## Core ML conversion of SHARP: `pearsonkyle/Sharp-coreml`

- **What:** a community Core ML (`.mlpackage`) conversion of SHARP, published on Hugging Face at [pearsonkyle/Sharp-coreml](https://huggingface.co/pearsonkyle/Sharp-coreml). It is not affiliated with Apple's paper.
- **Licence:** `apple-amlr`, the same Apple Machine Learning Research Model License as above.

## Spark (World Labs)

- **File:** `AutoSplat/Resources/spark.module.js`, the Gaussian splat renderer.
- **Licence:** MIT, Copyright © 2025 World Labs Technologies, Inc. See [`licenses/spark-MIT.txt`](licenses/spark-MIT.txt) and [sparkjsdev/spark](https://github.com/sparkjsdev/spark).

## three.js

- **Files:** `AutoSplat/Resources/three.core.js` and `three.module.js` (r178). `AutoSplat/Resources/OrbitControls3d.js` is three.js's `OrbitControls` from `examples/jsm/controls`.
- **Also derived from three.js:** the stereo effects in `AutoSplat/Resources/gaus3d.html` are adapted from three.js's `ParallaxBarrierEffect` and `AnaglyphEffect` examples. The anaglyph matrices were originally generated with [angler.js](https://github.com/tschw/angler.js) by tschw; no angler.js code is included.
- **Licence:** MIT, Copyright © 2010–2025 three.js authors. See [`licenses/three.js-MIT.txt`](licenses/three.js-MIT.txt).
