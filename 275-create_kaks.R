
mut = tbl(con, 'mutation')
mut..types = mut %>% pull(effect) %>% unique

nonsilent = c("Missense_Mutation","In_Frame_Del","Nonsense_Mutation", "In_Frame_Ins","Frame_Shift_Del",
    "Nonstop_Mutation", "Frame_Shift_Ins","Translation_Start_Site")

silent = mut..types [ ! mut..types %in% nonsilent ]

mutplus = mut %>% select( sample, effect ) %>% collect %>%
    mutate( effect = case_when(
                effect %in% nonsilent ~ 'nonsilent',
                TRUE ~ 'silent'
        )
           )

mutsum = mutplus %>% group_by(sample) %>%
    summarize(
        kaks = length(which( effect == 'nonsilent' )) / ( length(which( effect == 'silent')) + length(which( effect == 'nonsilent')) )
        )
    
    

## prep for db loading
my_load = mutsum %>%
    rename(value = kaks) %>%
        mutate( probe = "kaks", type = "kaks" ) %>%
            select( sample, probe, value, type )

tablemaker( my_load, deleteType = TRUE, suffix = TRUE)

##sqldf::sqldf('select * from tcgas where type = "kaks" limit 10', con = con )










