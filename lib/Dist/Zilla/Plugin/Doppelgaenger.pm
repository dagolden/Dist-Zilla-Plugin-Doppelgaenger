use strict;
use warnings;
package Dist::Zilla::Plugin::Doppelgaenger;
# ABSTRACT: Creates an evil twin of a CPAN distribution

use Moose;
use Moose::Autobox;
use MooseX::Types::Path::Class qw(Dir File);
use MooseX::Types::URI qw(Uri);
use MooseX::Types::Perl qw(ModuleName);
with 'Dist::Zilla::Role::FileGatherer';

use File::Find::Rule;
use File::pushd qw/tempd/;
use Path::Class;
use Pod::Strip;
use Archive::Extract;
use HTTP::Tiny;
use JSON;

use namespace::autoclean;

=attr source_module (REQUIRED)

The name of a CPAN module to imitate.  E.g. Foo::Bar

=cut

has source_module => (
  is    => 'ro',
  isa   => ModuleName,
  required => 1,
);
  
=attr new_name (REQUIRED)

The new name to use in place of the source name

=cut

has new_name => (
  is    => 'ro',
  isa   => ModuleName,
  required => 1,
);

=attr cpan_mirror

This is a URI to a CPAN mirror.  Defaults to C<http://cpan.dagolden.com/>
It may be any URI that L<File::Fetch> can cope with.

=cut

has cpan_mirror => (
  is    => 'ro',
  isa   => Uri,
  coerce => 1,
  default => 'http://cpan.dagolden.com/'
);
  
has _cpanidx => (
  is    => 'ro',
  isa   => Uri,
  coerce => 1,
  default => 'http://cpanidx.org/',
);


sub gather_files {
  my ($self) = @_;

  my $distfile = $self->_distfile
    or die "Could not find distfile for " . $self->source_module . "\n";

  my $wd = tempd;
  my $tarball = $self->_download($distfile);
  my $ae = Archive::Extract->new( archive => $tarball );
  $ae->extract
    or die "Couldn't unpack $tarball: " . $ae->error;

  my ($extracted) = grep { -d } dir($wd)->children;
  die "Couldn't find untarred folder for $tarball\n"
  unless $extracted;

  FILE: for my $filename ( $ae->files ) {
    my $file = file($filename)->relative($extracted);
    next FILE if $file->basename =~ qr/^\./;
    next FILE if grep { /^\.[^.]/ } $file->dir->dir_list;
    my $dz_file = $self->_file_from_filename($filename);
    (my $newname = $dz_file->name) =~ s{\A\Q$extracted\E[\\/]}{}g;
    $newname = Path::Class::dir($newname)->as_foreign('Unix')->stringify;

    $dz_file->name($newname);
    $self->_munge_file($dz_file);
    $self->add_file($dz_file);
  }

  return;
}

sub _munge_file {
  my ($self, $file) = @_;

  my $old_name = $self->source_module;
  my $new_name = $self->new_name;
  
  my $content = $file->content;
  $content =~ s{$old_name}{$self->new_name}g;
  $file->content($content);
}

sub _download {
  my ($self, $distfile) = @_;
  (my $tarball = $distfile) =~ s{\A.*/([^/]+)\z}{$1};
  my $uri = file($self->cpan_mirror, qw/authors id/, $distfile); 
  my $response = HTTP::Tiny->new->mirror("$uri", $tarball);
  die "Could not download $uri\n"
    unless $response->{success};
  return $tarball;
}

sub _distfile {
  my ($self) = @_;
  my $mod = $self->source_module;
  my $uri = file($self->_cpanidx,qw/cpanidx mod/,$mod);
  my $response = HTTP::Tiny->new->get("$uri");
  die "Could not find $mod via $uri\n"
    unless $response->{success};

  my $meta = eval { decode_json($response->{content}) };
  return $meta->{distfile};
}

sub _file_from_filename {
  my ($self, $filename) = @_;

  return Dist::Zilla::File::OnDisk->new({
    name => $filename,
    mode => (stat $filename)[2] & 0755, # kill world-writeability
  });
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;

=for Pod::Coverage gather_files

=begin wikidoc

= SYNOPSIS

  use Dist::Zilla::Plugin::Doppelgaenger;

= DESCRIPTION

This [Dist::Zilla] plugin creates a new CPAN distribution with a new name based
on a source distribution.

Please do not do this without the permission of the authors or maintainers
of the source.

=end wikidoc

=cut

