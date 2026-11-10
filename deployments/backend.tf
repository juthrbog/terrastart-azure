# The backend settings for each deployment are in
# deployments/backends/<deployment>.s3.tfbackend. CI (.ci/scripts/tf.sh) and
# `task tf-switch` pass that file to `tofu init -backend-config=...`.
terraform {
  backend "s3" {}
}
