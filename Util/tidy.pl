#!/usr/bin/perl
use Math::Round;

$fline = <>;
@samples = split('\t', $fline);
shift(@samples);
$slength = @samples;

print("sample,variable,value\n");

while(<>) {
    @data = split('\t');
    $probe = shift(@data);
    chomp($probe);
    for( $i = 0; $i < $slength; $i++) {
	$sample = $samples[$i]; chomp($sample);
	$datum = $data[$i]; chomp($datum);
	$datum = nearest(0.01, $datum);
	print("$sample,$probe,$datum\n")
    }
}


	
