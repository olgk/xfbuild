dmd -op -c -lib a/Foo.d b/Foo.d -ofFoo.lib
lib -l Foo.lib
lib -x Foo.lib Foo
lib -d Foo.lib Foo
rename Foo.obj a.obj
lib -x Foo.lib Foo
lib -d Foo.lib Foo
rename Foo.obj b.obj
lib -l a.obj
lib -l b.obj
pause
