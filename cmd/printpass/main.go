// printpass 仅用于测试：解析 -p 参数并原样打印到 stdout，用于复现「通过 shell 传参时特殊字符被篡改」的问题。
// 用法: printpass -p 'Oracle1!'
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	p := flag.String("p", "", "password (for testing)")
	flag.Parse()
	fmt.Fprint(os.Stdout, *p)
}
