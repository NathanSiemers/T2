# Pancan_Database_2018

Good morning, Peter.

Thanks!  I’ve got ¾ of RWC Tbio using the data on a daily basis.  And the last holdout (Jim) built own his copy last week.

You’ll need about 40 gB of disk.

Grab a copy of the repository: https://biogit.pri.bms.com/siemersn/Pancan_Database_2018

You may need to install a couple packages if they aren’t on your system, not too many (sqldf ggthemes…). Make sure proxies are set up.

There’s a runBatch.sh script that downloads everything from UCSC and builds a sqlite database.

The database is super-simple to use via dbplyr connections or sqldf sql.  See the top lines of ‘lib.R’ for examples on how to establish connections.  If you haven’t used a db connection in dplyr before, you’ll need to keep in mind that not every dplyr command is supported, but most are.
•	occasionally you need to add a %>% data.frame to your workflow
•	the main views that have useful information
o	tcga – tcga numerical information + clinical annotation
o	tcgacat – tcga categorical information + clinical annotation
o	tcgas – tcga numerical information without extra annotation
o	tcgacats
o	the above tables are all tidy wrt probe and sample -> value
	you’ll need a one-line ‘spread’ to spread them out (easy in dplyr, not easy to do in sql)
•	There’s also a master retrieval function, gitr() in lib.R, that pulls data for you and does the spread
•	There’s a master plotter function plotter(), that retrieves data via gitr() and plots

The shiny app is there too, ready to go.

Let me know of any problems, and enjoy.  Over the past week, I’ve added ESTIMATE purity scores to the db, thresholded copy number data (*.cnc), and the ability to condition x or y (or both) on one or more other variables (like purity and tmb, for example).   Finally, there’s also an attempt at the Merck 18 signature (Merck18.sig), where I’ve applied all the weights that they were recently (finally) forced to disclose in a publication.  It goes without saying that the best signature (BMS4.sig) is available for use.

Nato
