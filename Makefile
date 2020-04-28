bin: src/mrb_bytecode.c src/mrb_wrapper.c
	musl-gcc -std=c99 -static -Isrc/mruby/include src/mrb_wrapper.c src/mruby/build/host/lib/libmruby.a -o bin/hello
	strip -g bin/hello
	upx -7 bin/hello

src/mrb_bytecode.c: src/main.rb src/mruby/build/host/bin/mrbc
	src/mruby/build/host/bin/mrbc -Bmrb_bytecode -o src/mrb_bytecode.c src/main.rb

src/mruby/build/host/bin/mrbc: src/mruby
	cd src/mruby; sed -i -e 's/^end\$\/  # static-rb\n  conf.gem :core => "mruby-io"\n  conf.gem :core => "mruby-socket"\n  conf.gem :github => "Asmod4n/mruby-phr"\nend # static-rb/' mrbgems/default.gembox; CC=musl-gcc make

src/mruby: packages
	mkdir -p src
	#git clone -q git@github.com:/mruby/mruby.git src/mruby
	cd src/mruby; git checkout .; git pull

packages:
	sudo apt -y install musl-dev upx-ucl build-essential bison ruby
