# Starter pomocnika Now Playing Wokyintosha.
# Systemowy perl jest podpisany przez Apple, więc MediaRemote odpowiada
# bibliotece załadowanej do jego procesu. Samo ładowanie (dl_load_file) trzyma
# blokadę dyld, więc pętla pomocnika NIE działa w konstruktorze biblioteki —
# zamiast tego wołamy wyeksportowaną NowPlayingHelperRun dopiero po zakończeniu
# ładowania, przez sztuczkę z XSUB-em (dl_find_symbol + dl_install_xsub). Funkcja
# nie wraca; wyjście z tego skryptu oznacza błąd ładowania.
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV;
unless (defined $library) {
    print STDERR "nowplaying-helper: brak ścieżki do biblioteki\n";
    exit 2;
}
my $lib = DynaLoader::dl_load_file($library, 0);
unless ($lib) {
    print STDERR "nowplaying-helper: ", DynaLoader::dl_error(), "\n";
    exit 2;
}
my $symbol = DynaLoader::dl_find_symbol($lib, "NowPlayingHelperRun");
unless ($symbol) {
    print STDERR "nowplaying-helper: ", DynaLoader::dl_error(), "\n";
    exit 2;
}
DynaLoader::dl_install_xsub("NowPlayingHelper::run", $symbol);
NowPlayingHelper::run();
exit 2;
