package scripts

import "embed"

//go:embed sql os
var defaultEmbeddedFS embed.FS
