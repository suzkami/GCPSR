#!/usr/bin/perl -w
use strict;
use Bio::Tree::Tree;
#use Bio::Tree::Draw::Cladogram;
use Bio::TreeIO;

# Number the clades
my $clade_count = 0;
# Store the members of the clades and the support
my $clades_h = {};
my $clades_c = {};
# Store the strain ids
my $allids = {};

# Deafult minimum support for clades to be kept
my $min = 1;
my ($count_par) = grep{/^-count=(\d+)$/} @ARGV;
if ($count_par) {
    $count_par =~ /^-count=(\d+)$/;
    $min = $1;
}

# Test for arguments that won't be processed
my @not_used = grep{$_ ne "-"} grep{$_ !~ /^-count=(\d+)$/} grep{$_ !~ /\.nwk$/} grep{$_ !~ /\.nex\.\S+\.t(re)$/} @ARGV;
if (@not_used) {
    for (@not_used) {
	if (/^(-)?-h(elp)?$/) {
	    last;
	}
	print{*STDERR} "'$_' is an incorrect argument\n";
    }
    die "Usage:\n\t$0 [-h | --help] [-count=<int>] tree\n" .
	"Description:\n\tA tool to implement the exhaustive subdivision analysis of GCPSR sensu Brankovics et al. 2017\n" .
	"Input:\ttree\n" .
	"\tTree file produced by the concordance and non-discordance analysis of GCPSR sensu Brankovics et al. 2017.\n" .
	"\tTree file in either newick or nexus format with the number of single locus trees supporting a clade as support values.\n" .
	"\tThe input is either read from the specified file or from the STDIN (standard input) if '-' was specified as tree.\n" .
	"Options:\n" .
	"\t-h | --help\n\t\tPrint the help message; ignore other arguments.\n" .
	"\t-count=<int>\n\t\tAll clades that are supported by less then <int> majority-rule concensus trees\n" .
	"\t\t(support value in the tree file) will not be considered as phylogenetic species. (Default: 1)\n" .
	"\n";
}



# Process the input
for (@ARGV) {
    my $input;
    # Open trees or store minsupport value
    if (/\.nwk$/) {
	$input = new Bio::TreeIO(-file   => $_,
				 -format => "newick");
    } elsif (/\.nex\.\S+\.t(re)$/) {
	$input = new Bio::TreeIO(-file   => $_,
				 -format => "nexus");
    } elsif ("-" eq $_) {
	$input = new Bio::TreeIO(-fh   => \*STDIN,
				 -format => "newick");
    }
    # Read the tree in the file
    next unless $input;
    my $tree = $input->next_tree;

    ## Save image
    #my $obj1 = Bio::Tree::Draw::Cladogram->new(-tree => $tree, -bootstrap => 1, compact => 1);#);
    #$obj1->print(-file => "before_cladogram_.eps");

    my $rootn = $tree->get_root_node;
    # Collect all the strain ids
    for ($rootn->get_all_Descendents()) {
	$allids->{&get_id($_)}++ if $_->is_Leaf;
    }
    # Collect Clade data
    &collect_clades($tree, $clades_h, $clades_c, \$clade_count);
}

# Collect all the clade ids and store it in hash as keys
my %clade_ids;
for (keys %$clades_h) {
    $clade_ids{$_}++;
}

# Exhaustive subdivision (returns the clade ids that are kept)
my $final = &sub_div($allids, \%clade_ids, $clades_h, $clades_c);

# Print final newick tree
print "(" . &create_tree($allids, $final, $clades_h, $clades_c) . ");\n";

#=============Subroutines================================================
sub sub_div{
    # Exhaustive subdivision
    #    Classifies each strain into a phylogenetic species
    #    Find the smallest clade with sufficient support that contains the strain
    #    Remove all subclades of such clades
    # Inputs are hash references:
    # strain ids, clade id numbers, clade hash (id->array of members), clade support hash
    my ($names, $ids, $clade, $count) = @_;
    RANK: for my $id (sort keys %$names) {
	# Get the smallest clade that contains the strain
	my ($now) = grep{ # only clades that contain the strain
	                   my $get;
                           for (@{ $clade->{$_} }){
                             $get++ if $id eq $_
                           };
                           $get
                         } sort{ # sort clades based on number of strains; ascending
                                  scalar(@{ $clade->{$a} }) <=> scalar(@{ $clade->{$b} })
                                } keys %$ids;
	# If there are no clades (left) containing the strain return NULL
	return unless $now;
	# Remove all subclades of this clade
	for (keys %$ids) {
	    next if $now eq $_; # skip if it is the selected clade
	    if (&is_subset($clade->{$_}, $clade->{$now})){
		delete $ids->{$_};
	    }
	}
	# Check that it has sufficient support 
	if ($count->{$now} < $min && scalar keys %$ids > 1) {
	    # Remove the clade and search for the smallest clade containing the strain
	    delete $ids->{$now};
	    redo RANK;
	}
    }
    return $ids;
}

sub create_tree{
    # Return a newick string
    # all the inputs are references to hashes
    # strain ids, clade id numbers, clade hash (id->array of members), clade support hash
    my ($names, $ids, $clade, $count) = @_;

    # If no more clades in ids then return the remaining strains
    if (scalar(keys %$ids) == 0) {
	return join(",", sort keys %$names);
    } else {
	# Group clades as "super" sets and subsets
	# (store the ids of subsets for the id of the superset)
	my %super;
	# Repeat until all of them are categorized
	while(keys %$ids) {
	    # Get the largest clade (sort based on number of members)
	    my ($now) = sort{scalar(@{ $clade->{$b} })<=>scalar(@{ $clade->{$a} })} keys %$ids;
	    delete $ids->{$now}; # Remove superclade
	    # Find subclusters, add them to the hash
	    $super{$now} = {};
	    for (keys %$ids) {
		if (&is_subset($clade->{$_}, $clade->{$now})){
		    $super{$now}->{$_}++;
		    delete $ids->{$_};
		}
	    }
	}
	# Delete the strain names that are contained in the superclades
	# (they contain every id that are inside all the clades)
	for (keys %super) {
	    for (@{$clade->{$_}}) {
		delete $names->{$_};
	    }
	}
	# Recursive call for each superclade
	my $tree = join(",", map{# Create an anonymus hash to store the ids inside the super clade
	                         my $ns;
				 for (@{ $clade->{$_} }){
				     $ns->{$_}++
				 };
				 "(" . create_tree($ns,        # members of the clade
						   $super{$_}, # List of subclades
						   $clade,     # the two clade hash references
						   $count) . ")$count->{$_}"
			                                                    } sort{scalar(@{ $clade->{$b} })<=>scalar(@{ $clade->{$a} })} keys %super);
	# Append the remaining ids if there are
	return join(",", $tree, sort keys %$names);
    }
}

sub get_id{
    # Help get clean data from nodes
    my ($n) = @_;
    my $res = $n->id;
    $res =~ s/\s+$//;
    return $res;
}

sub get_children{
    # Returns an array of all the leafs of the given node
    my ($node) = @_;
    my @children;
    # Examine all its descendants
    for ($node->get_all_Descendents()) {
	# Get the name of the leaves
	next unless $_->is_Leaf;
	my $id = &get_id($_);
	push @children, $id;
    }
    return sort @children;
}

sub collect_clades{
    # Collect clade data from the tree
    # All the inputs are references
    # Inputs: Tree, hash to store the clades, hash to store clade support and integer for clade numbering
    my ($tree, $hash, $count, $i) = @_;
    # Get root
    my $root = $tree->get_root_node;
    # Go through all nodes
    for my $n ($root->get_all_Descendents()) {
	# Skip leaves
	next if $n->is_Leaf;
	# Get clade members, add to hash
	my $new++;
	my @clade = get_children($n);
	for (keys %$hash) {
	    my @now = @{ $hash->{$_} };
	    # Search already stored clades, whether it is already present
	    if (scalar(@now) == scalar(@clade)) {
		my %test;
		for (@now, @clade) {
		    $test{$_}++;
		}
		if (scalar(@now) == scalar(keys %test)) {
		    $new = 0;
		    # Add clade support
		    $count->{$_} += &get_id($n);
		}
	    }
	}
	if ($new && scalar @clade > 1) {
	    # Increment the clade id
	    $$i++;
	    # Add clade support
	    $count->{$$i} = &get_id($n);
	    $hash->{$$i} = \@clade;
	}
    }
}

sub is_subset{
    # return true if a is subset of b
    # inputs are references to arrays
    my ($a, $b) = @_;
    my $found = 0;
    for my $i (@$a) {
	for my $j (@$b) {
	    $found++ if $i eq $j;
	}
    }
    # A is a subset of B if all the elements of A are found in B
    return $found == scalar @$a;
}
