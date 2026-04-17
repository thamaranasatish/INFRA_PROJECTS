Place the ignition files produced by `openshift-install create ignition-configs`
into this directory before `terraform apply`:

  bootstrap.ign
  master.ign
  worker.ign

These are embedded into VM extra_config via base64. Do not commit them — they
contain the cluster's initial pull-secret and TLS material. Add `*.ign` to
.gitignore.
