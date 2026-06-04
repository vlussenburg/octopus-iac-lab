package main

import rego.v1

# Allow only images from this lab's GHCR namespace.
# Trips on typos and any pull from an unintended registry.

allowed_registries := ["ghcr.io/vlussenburg/"]

deny contains msg if {
	input.kind == "Deployment"
	some i
	image := input.spec.template.spec.containers[i].image
	not allowed_image(image)
	msg := sprintf(
		"container[%d] image %q not from an allowed registry (%v)",
		[i, image, allowed_registries],
	)
}

allowed_image(image) if {
	some prefix in allowed_registries
	startswith(image, prefix)
}
