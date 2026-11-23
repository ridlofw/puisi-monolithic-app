#!/bin/sh
# gateway dianggap sehat bila nginx masih melayani halaman utama
wget -q -T 1 -O /dev/null http://127.0.0.1/sehat-gateway || exit 1
