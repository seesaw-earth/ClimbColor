CLIMBCOLOR CORE ML MODEL

The trained ClimbHoldSeg.mlpackage is included in this repository using Git LFS.

After cloning the repository, run:

git lfs install
git lfs pull

The Xcode build phase compiles:

ClimbColor/Models/ClimbHoldSeg.mlpackage

into the app bundle as:

ClimbHoldSeg.mlmodelc

If the model is missing, the build intentionally fails instead of producing
an App Store binary without the on-device model.
