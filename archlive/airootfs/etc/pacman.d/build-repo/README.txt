这个目录用于存放自编译的 Calamares 包。

正常流程下它应该是空的，由 build/build-calamares.sh 填充：
  1. 在【构建机】上以普通用户运行 bash build/build-calamares.sh
  2. 它会 makepkg 出 calamares-<ver>-<rel>.pkg.tar.zst
  3. 把它连同 repo-add 生成的 .db.tar.gz 一起复制到这个目录

ISO 构建时（mkarchiso）会先把 airootfs 打包，再从宿主 pacman 数据库取包。
如果本地 [build] 源在宿主上可见，pacman 就能直接把 calamares 装进 ISO，
这时这个 ISO 内的目录不会被用到 —— 两种方式都可以，构建机上二选一。

如果这个目录是空的、宿主也没配 [build] 源，
build/preflight.sh 会报 calamares 缺失，ISO 会构建失败。
