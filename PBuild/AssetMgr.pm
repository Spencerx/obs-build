################################################################
#
# Copyright (c) 2021 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

package PBuild::AssetMgr;

use strict;

use Digest::MD5 ();

use PBuild::Util;
use PBuild::Source;
use PBuild::RemoteAssets;
use PBuild::Cpio;

our $goproxy_default = 'https://proxy.golang.org';

#
# Create the asset manager
#
sub create {
  my ($assetdir) = @_;
  return bless { 'asset_dir' => $assetdir, 'handlers' => [] };
}

#
# Add a new asset resource to the manager
#
sub add_assetshandler {
  my ($assetmgr, $assetsurl) = @_;
  my $type = '';
  $type = $1 if $assetsurl =~ s/^([a-zA-Z0-9_]+)\@//;
  if ($type eq 'fedpkg') {
    push @{$assetmgr->{'handlers'}}, { 'url' => $assetsurl, 'type' => $type };
  } elsif ($type eq 'goproxy') {
    push @{$assetmgr->{'handlers'}}, { 'url' => $assetsurl, 'type' => $type };
  } else {
    die("unsupported assets url '$assetsurl'\n");
  }
}

#
# Calculate the asset id used to cache the asset on-disk
#
sub get_assetid {
  my ($file, $asset) = @_;
  return $asset->{'assetid'} if $asset->{'assetid'};
  my $digest = $asset->{'digest'};
  if ($digest) {
    return Digest::MD5::md5_hex("$digest  $file");
  } elsif ($asset->{'url'}) {
    return Digest::MD5::md5_hex("$asset->{'url'}  $file");
  } else {
    die("$file: asset must either have a digest or an url\n");
  }
}

#
# calculate an id that identifies an mutable asset
#
sub calc_mutable_id {
  my ($assetmgr, $asset) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetmgr->{'asset_dir'}/".substr($assetid, 0, 2);
  my $fd;
  if (open($fd, '<', "$adir/$assetid")) {
    # already have it, use md5sum to track content
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fd);
    close $fd;
    return $ctx->hexdigest();
  }
  # not available yet, use "download on demand" placeholder
  return 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
}

#
# Add the asset information to the package's srcmd5
#
sub update_srcmd5 {
  my ($assetmgr, $p) = @_;
  my $old_srcmd5 = $p->{'srcmd5'};
  return 0 unless $old_srcmd5;
  my $asset_files = $p->{'asset_files'};
  return 0 unless %{$asset_files || {}};
  my %files = %{$p->{'files'}};
  for my $file (sort keys %$asset_files) {
    my $asset = $asset_files->{$file};
    die unless $asset->{'assetid'};
    # use first part of digest if we have one
    if ($asset->{'digest'} && $asset->{'digest'} =~ /:([a-f0-9]{32})/) {
      $files{$file} = $1;
    } elsif ($asset->{'immutable'}) {
      $files{$file} = substr($asset->{'assetid'}, 0, 32);
    } else {
      $files{$file} = calc_mutable_id($assetmgr, $asset);
    }
  }
  $p->{'srcmd5'} = PBuild::Source::calc_srcmd5(\%files);
  return $p->{'srcmd5'} eq $old_srcmd5 ? 0 : 1;
}

#
# Merge assets into the asset_files hash
#
sub merge_assets {
  my ($assetmgr, $p, $assets) = @_;
  my $files = $p->{'files'};
  for my $asset (@{$assets || []}) {
    my $file = $asset->{'file'};
    if (!$assetmgr->{'keep_all_assets'}) {
      # ignore asset if present in source list
      next if $files->{$file} || $files->{"$file/"};
    }
    $asset->{'assetid'} ||= get_assetid($file, $asset);
    $p->{'asset_files'}->{$file} = $asset;
  }
}

#
# Generate asset information from the package source
#
sub find_assets {
  my ($assetmgr, $p) = @_;
  my $bt = $p->{'buildtype'} || '';
  my @assets;
  push @assets, @{$p->{'source_assets'} || []};
  push @assets, PBuild::RemoteAssets::fedpkg_parse($p) if $p->{'files'}->{'sources'};
  push @assets, PBuild::RemoteAssets::golang_parse($p) if $p->{'files'}->{'go.sum'};
  push @assets, PBuild::RemoteAssets::recipe_parse($p) if $bt eq 'spec' || $bt eq 'kiwi' || $bt eq 'arch' || $bt eq 'apk' || $bt eq 'docker';
  merge_assets($assetmgr, $p, \@assets);
  update_srcmd5($assetmgr, $p) if $p->{'asset_files'};
}

#
# Does a package have assets that may change over time?
#
sub has_mutable_assets {
  my ($assetmgr, $p) = @_;
  for my $asset (values %{$p->{'asset_files'} || {}}) {
    return 1 unless $asset->{'digest'} || $asset->{'immutable'};
  }
  return 0;
}

#
# remove the assets that we have cached on-disk
#
sub prune_cached_assets {
  my ($assetmgr, @assets) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my @pruned;
  for my $asset (@assets) {
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    push @pruned, $asset unless -e "$adir/$assetid";
  }
  return @pruned;
}

#
# Make sure that we have all remote assets in our on-disk cache
#
sub getremoteassets {
  my ($assetmgr, $p) = @_;
  my $asset_files = $p->{'asset_files'};
  return unless $asset_files;

  my $assetdir = $assetmgr->{'asset_dir'};
  my %assetid_seen;
  my @assets;
  # unify over the assetid
  for my $asset (map {$asset_files->{$_}} sort keys %$asset_files) {
    push @assets, $asset unless $assetid_seen{$asset->{'assetid'}}++;
  }
  @assets = prune_cached_assets($assetmgr, @assets);
  for my $handler (@{$assetmgr->{'handlers'}}) {
    last unless @assets;
    if ($handler->{'type'} eq 'fedpkg') {
      PBuild::RemoteAssets::fedpkg_fetch($p, $assetdir, \@assets, $handler->{'url'});
    } elsif ($handler->{'type'} eq 'goproxy') {
      PBuild::RemoteAssets::golang_fetch($p, $assetdir, \@assets, $handler->{'url'});
    } else {
      die("unsupported assets type $handler->{'type'}\n");
    }
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (grep {($_->{'type'} || '') eq 'ipfs'} @assets) {
    PBuild::RemoteAssets::ipfs_fetch($p, $assetdir, \@assets);
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (grep {($_->{'type'} || '') eq 'golang'} @assets) {
    if (!grep {$_->{'type'} eq 'goproxy'} (@{$assetmgr->{'handlers'}})) {
      PBuild::RemoteAssets::golang_fetch($p, $assetdir, \@assets, $goproxy_default);
      @assets = prune_cached_assets($assetmgr, @assets);
    }
  }
  if (grep {($_->{'type'} || '') eq 'url'} @assets) {
    PBuild::RemoteAssets::url_fetch($p, $assetdir, \@assets);
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (@assets) {
    my @missing = sort(map {$_->{'file'}} @assets);
    print "missing assets: @missing\n";
    $p->{'error'} = "missing assets: @missing";
    return;
  }
  update_srcmd5($assetmgr, $p) if has_mutable_assets($assetmgr, $p);
}

sub unpack_obscpio_asset {
  my ($assetmgr, $obscpio, $srcdir, $file) = @_;
  PBuild::Cpio::cpio_extract($obscpio, sub {
    my $name = $_[0]->{'name'};
    !$_[1] && ($name eq $file || $name =~ /^\Q$file\E\//) ? "$srcdir/$name" : undef
  }, 'postpone_symlinks' => 1, 'set_mode' => 1, 'set_mtime' => 1);
}

#
# Copy the assets from our cache to the build root
#
sub copy_assets {
  my ($assetmgr, $p, $srcdir, $unpack) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    die("asset $assetid is gone\n") unless -e "$adir/$assetid";
    if ($asset->{'isdir'} && $unpack) {
      for my $unpackfile (@{$asset->{'filelist'} || [ $file ]}) {
        PBuild::Util::rm_rf("$srcdir/$unpackfile");
        unpack_obscpio_asset($assetmgr, "$adir/$assetid", $srcdir, $unpackfile);
      }
      next;
    }
    unlink($asset->{'isdir'} ? "$srcdir/$file.obscpio" : "$srcdir/$file");
    PBuild::Util::cp("$adir/$assetid", $asset->{'isdir'} ? "$srcdir/$file.obscpio" : "$srcdir/$file");
  }
  if (has_mutable_assets($assetmgr, $p) && update_srcmd5($assetmgr, $p)) {
    copy_assets($assetmgr, $p, $srcdir);	# had a race, copy again
  }
}

#
# Move the assets from our cache to the build root, destroying the cache
#
sub move_assets {
  my ($assetmgr, $p, $srcdir, $unpack) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    die("asset $assetid is gone\n") unless -e "$adir/$assetid";
    if ($asset->{'isdir'}) {
      if ($unpack && ! -d "$adir/$assetid") {
	PBuild::Util::rm_rf("$srcdir/$file");
	unpack_obscpio_asset($assetmgr, "$adir/$assetid", $srcdir, $file);
	next;
      }
      if (!$unpack && -d "$adir/$assetid") {
	die("packing of assets is not supported\n");
      }
      $file .= ".obscpio" if !$unpack;
    }
    rename("$adir/$assetid", "$srcdir/$file") || die("rename $adir/$assetid $srcdir/$file: $!\n");
  }
  if (has_mutable_assets($assetmgr, $p) && update_srcmd5($assetmgr, $p)) {
    die("had a race in move_assets\n");
  }
}

1;
