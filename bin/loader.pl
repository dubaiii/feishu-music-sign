use strict; use warnings; use DynaLoader;
my $dylib_path = shift @ARGV or exit 1;
my $command = shift @ARGV // "get";
exit 1 unless -e $dylib_path;
my $handle = DynaLoader::dl_load_file($dylib_path, 0) or exit 1;
my $symbol_name =
    $command eq "test" ? "adapter_test" :
    $command eq "stream" ? "adapter_stream_env" :
    "adapter_get_env";
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name) or exit 1;
DynaLoader::dl_install_xsub("main::run", $symbol);
eval { main::run(); };
exit($@ ? 1 : 0);
