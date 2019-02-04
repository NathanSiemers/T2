#!/usr/bin/perl
use Math::Round;

$fline = <>;
@samples = split('\t', $fline);
shift(@samples);
$slength = @samples;
$probe = 0;
##print("sample,variable,value\n");

while(<>) {
    @data = split('\t');
    shift(@data);
    $probe++;
    for( $i = 0; $i < $slength; $i++) {
	$sample = $i + 1;
	$datum = $data[$i]; chomp($datum);
	$datum = nearest(0.001, $datum);
	print("$sample,$probe,$datum\n")
    }
}


	
