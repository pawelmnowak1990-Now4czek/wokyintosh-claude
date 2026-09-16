# Starter pomocnika Now Playing Wokyintosha.
# Systemowy perl jest podpisany przez Apple, więc MediaRemote odpowiada
# bibliotece załadowanej do jego procesu. Pętla pomocnika działa w konstruktorze
# biblioteki i nie wraca; wyjście z tego skryptu oznacza błąd ładowania.
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV;
unless (defined $library) {
    print STDERR "nowplaying-helper: brak ścieżki do biblioteki\n";
    exit 2;
}
DynaLoader::dl_load_file($library, 0) or do {
    print STDERR "nowplaying-helper: ", DynaLoader::dl_error(), "\n";
    exit 2;
};
exit 2;
