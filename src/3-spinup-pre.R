## stsimcbmcfs3 - spinup pre
## ApexRMS, January 2022

# Run with R-4.1.1
# Spin-up pre-processing script 

# Source helper functions
pkg_dir <- (Sys.getenv("ssim_package_directory"))
source(file.path(pkg_dir, "0-dependencies.R"))
source(file.path(pkg_dir, "0-helper-functions.R"))

myLibrary <- ssimLibrary()
myProject <- project()
myScenario <- scenario()

# (1) Extract spinup datasheet from library -------------------------------
spinup <- datasheet(myScenario, "stsimcbmcfs3_Spinup", optional=TRUE) %>%
  mutate_if(is.factor, as.character) 

# Check that primary stratum does not mix unspecified (wildcard) and specified (non-wildcard) values
stratum_check <- spinup %>%
  mutate(StratumIsSpecified = ifelse(is.na(StratumID), 0, 1)) %>%
  summarize(Valid = ifelse(sum(StratumIsSpecified) == 0 | sum(StratumIsSpecified) == nrow(spinup), TRUE, FALSE))
if(!stratum_check$Valid)
  stop("The ST-Sim Stratum in the Spin-up datasheet has both specified and unspecified values.")

# Check that secondary stratum does not mix unspecified (wildcard) and specified (non-wildcard) values
secondary_stratum_check <- spinup %>%
  mutate(SecondaryStratumIsSpecified = ifelse(is.na(SecondaryStratumID), 0, 1)) %>%
  summarize(Valid = ifelse(sum(SecondaryStratumIsSpecified) == 0 | sum(SecondaryStratumIsSpecified) == nrow(spinup), TRUE, FALSE))
if(!secondary_stratum_check$Valid)
  stop("The ST-Sim Secondary Stratum in the Spin-up datasheet has both specified and unspecified values.")

# Create tertiary stratum
spinup <- spinup %>% 
  mutate(TertiaryStratumID = paste0("Last Disturbance: ", 
                                    strip_type(MostRecentDisturbanceTGID)))
# Throw error if empty
if (nrow(spinup) == 0){
  stop("Spinup datasheet is empty, conditions could not be initiated")
}

# Save tertiary stratum
unique_tertiary <- data.frame(Name = unique(spinup$TertiaryStratumID))
saveDatasheet(myProject, data = unique_tertiary, 
              name = "stsim_TertiaryStratum")

# save updated spinup
saveDatasheet(myScenario, data = spinup, 
              name = "stsimcbmcfs3_Spinup")


# (2) Impute Spinup params from CBM ---------------------------------------

if (is.null(spinup$HistoricalDisturbanceTGID)){
  # TODO script for inputation
  # Spinup duration, stratums and state class
  # can impute max age => use return interval
  # Can impute return invterval
  # historic can always be imputed => need to find it 
  # most recent => take historic 
}

# (3) Populate Run Control ------------------------------------------------

# Determine start and end
the_start <-  0
the_end <- spinup %>% 
  mutate(EndPerSpinupCombination = SpinupDuration * ReturnInterval + MaxAgeForLastCycle) %>%
  summarize(max(EndPerSpinupCombination)) %>%
  pull()

run_control <- data.frame(MinimumIteration = 1,
                          MaximumIteration = 1, 
                          MinimumTimestep = the_start, 
                          MaximumTimestep = the_end, 
                          IsSpatial = FALSE)
saveDatasheet(myScenario, data = run_control, name = "stsim_RunControl")

# (4) Populate Transition Multipliers -------------------------------------

# For each spinup unique row, determine the appropriate set of IC
spinup_unique <- unique(spinup)
nrow_unique <- nrow(spinup_unique)

final_df <- data.frame()
stratum_col <- c()

for (rownb in 1:nrow_unique){
  
  # Collect row-wise params
  the_row <- slice(spinup, rownb)
  stratum <- the_row$StratumID
  secondary_stratum <- the_row$SecondaryStratumID
  tertiary_stratum <- the_row$TertiaryStratumID
  
  state_class <- the_row$StateClassID
  dist_hist <- the_row$HistoricalDisturbanceTGID
  dist_last <- the_row$MostRecentDisturbanceTGID
  
  # If primary stratum is blank create a new primary stratum called "All" (changed to "[Unspecified]" to match template lib)
  if(is.na(stratum)){
    stratum <- "[Unspecified]" # "All"
    # stratum_definition <- data.frame(Name = stratum)
    # saveDatasheet(myProject, data = stratum_definition, name = "stsim_Stratum")
  }
  
  # Spinup cycles
  nb_cycles <- the_row$SpinupDuration
  interval_dist <- the_row$ReturnInterval
  
  spinup_duration <- nb_cycles*interval_dist
  
  # Create sequences
  ts_seq <- seq(from = 0, to = spinup_duration, by = interval_dist)
  ts_seq_add <- ts_seq + 1
  
  # Determine duration
  max_duration <- spinup %>% 
    select(ReturnInterval, SpinupDuration) %>% 
    rowSums() %>% 
    max()
  
  # Bind them
  temp_df <- bind_rows(data.frame(Timestep = ts_seq, Amount = 1), 
                       data.frame(Timestep = ts_seq_add, Amount = 0)) %>% 
    mutate(TransitionGroupID = dist_hist) %>% 
    mutate_if(is.factor, as.character)
  
  # Check if the 2 disturbances are the same
  if(dist_hist != dist_last){
    end_rows <- which(temp_df$Timestep %in% 
                        c(spinup_duration, spinup_duration + 1))
    temp_df[end_rows, ]$TransitionGroupID <- dist_last
    temp_df <- add_row(temp_df, Timestep = 0, Amount = 0, 
                       TransitionGroupID = dist_last)
  }
  
  # If there are any transition groups that are not 
  # included in the multipliers, set them to 
  # zero for the run.
  includedTransGroups = unique(temp_df$TransitionGroupID)
  allTransitionGroups = datasheet(myProject, name = "TransitionGroup")
  excludeTransitionGroups = filter(allTransitionGroups, Name != includedTransGroups & IsAuto == TRUE)
  nExclude = nrow(excludeTransitionGroups)
  
  if(nExclude>0){
    for (r in 1:nExclude){
      tg = excludeTransitionGroups[r,1]
      temp_df = addRow(temp_df, c(0,0,tg))
    }
  }
  
  # Add row params
  temp_df <-  temp_df %>% 
    mutate(StratumID = stratum, 
           SecondaryStratumID = secondary_stratum, 
           TertiaryStratumID = tertiary_stratum,
           StateClassID = state_class)
  
  final_df <- bind_rows(final_df, temp_df)
  stratum_col <- c(stratum_col, stratum)
}

final_df <- final_df %>% 
  arrange(Timestep) %>% 
  unique()

saveDatasheet(myScenario, data = final_df, 
              name = "stsim_TransitionMultiplierValue")

spinup$StratumID <- stratum_col
saveDatasheet(myScenario, data = spinup, 
             name = "stsimcbmcfs3_Spinup")

# (5) Populate initial Conditions -----------------------------------------

IC_nonspatial <- data.frame(TotalAmount = nrow_unique,
                            NumCells = nrow_unique,
                            CalcFromDist = TRUE)

IC_nonspatial_dist <- spinup %>% 
  select(StratumID, SecondaryStratumID, TertiaryStratumID, StratumID, StateClassID) %>% 
  mutate(AgeMin = 0, AgeMax = 0, RelativeAmount = 1)

saveDatasheet(myScenario, data = IC_nonspatial,
              name = "stsim_InitialConditionsNonSpatial")
saveDatasheet(myScenario, data = IC_nonspatial_dist,
              name = "stsim_InitialConditionsNonSpatialDistribution")


# (6) Set Output Options --------------------------------------------------

# output_options <- datasheet(myScenario, "stsim_OutputOptions")
# 
# output_options$SummaryOutputSC <- TRUE
# output_options$SummaryOutputSCTimesteps <- 1
# output_options$SummaryOutputTR <- TRUE
# output_options$SummaryOutputTRTimesteps <- 1
# 
# saveDatasheet(myScenario, data = output_options, 
#               name = "stsim_OutputOptions")


# (7) Transition Pathways -------------------------------------------------

transitions <- datasheet(myScenario, "stsim_Transition") %>% 
  mutate_if(is.factor, as.character)
deter_transitions <- datasheet(myScenario, "stsim_DeterministicTransition")

if (nrow(deter_transitions) == 0){
  stop("Deterministic Transitions datasheet is empty, transitions pathways could not be set")
}

all_disturbances <- 
  strip_type(unique(c(spinup_unique$MostRecentDisturbanceTGID, 
                      spinup_unique$HistoricalDisturbanceTGID)))

new_transitions <- deter_transitions %>% 
  select(-Location) %>% 
  expand_grid(TransitionTypeID = all_disturbances,
              Probability = 1) %>% 
  mutate_if(is.factor, as.character) %>% 
  as.data.frame()

transitions_final <- bind_rows(transitions, new_transitions) %>% 
  unique()

saveDatasheet(myScenario, data = transitions_final, name = "stsim_Transition")
