package scripts

import "embed"

// sql 和 os 目录由 build.sh 在编译前从仓库根目录 scripts/sql、scripts/os 复制到本目录。
// 嵌入后二进制可在任意位置运行并加载 we.sql 等脚本。
//
//go:embed sql os
var defaultEmbeddedFS embed.FS
