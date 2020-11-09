library(methods)
library(rsyncrosim)
library(tidyverse)
library(RODBC)
# Before running script make sure that Microsoft Access Database Engine is installed so that you can connect to a MS Access db from R x64bit
# On Sept 27 2018, I installed AccessDatabaseEngine_X64.exe from https://www.microsoft.com/en-us/download/details.aspx?id=13255

# Get ST-Sim library, project and scenario
myLibrary <- ssimLibrary()
myProject <- project(myLibrary, 1)
myScenario <- scenario()

# Get disturbance flow pathways - currently incomplete
doDisturbances = T

# Use CBM output to derrive expansion factors?
useCBMAgeVsCarbonCurves=T

# Source helper functions
pkg_dir <- (Sys.getenv("ssim_package_directory"))
source(file.path(pkg_dir, "helpers.R"))

###################################
# Get CBM database and crosswalks #
###################################
CBMDatabase <- datasheet(myLibrary, "stsimcbmcfs3_Database")[1,"Path"]
crosswalkStratumState <- datasheet(myScenario, "stsimcbmcfs3_CrosswalkSpecies", 
                                   optional = T)
NACount <- sum(is.na(crosswalkStratumState$SecondaryStratumID))
if (NACount > 0 && NACount < nrow(crosswalkStratumState)){
  stop("All secondary stratum must be specified or all must be left blank")
}
if (NACount == nrow(crosswalkStratumState)){
  SSIsWildCard <-  TRUE
}
crosswalkStock <- datasheet(myScenario, "stsimcbmcfs3_CrosswalkStock")

# crosswalkStock[16, 1] <- "Products"

#crosswalkTransition <- datasheet(myScenario, "CBMCFS3_CrosswalkDisturbance")

# Crosswalk functions
crossSF <- function(CBMStock){ as.character(crosswalkStock$StockTypeID[crosswalkStock$CBMStock==CBMStock])}
#crossTG  <- function(CBMDisturbace){ as.character(crosswalkTransition$DisturbanceTypeID[crosswalkTransition$CBMTransitionGroupID==CBMDisturbance])}

# Identify biomass and DOM stocks
biomassStocks <- unlist(lapply(c("Merchantable", "Foliage", "Other", "Coarse root", "Fine root"), crossSF))
DOMStocks <- unique(unlist(lapply(c("Aboveground Very Fast DOM", "Aboveground Fast DOM", "Aboveground Medium DOM", "Aboveground Slow DOM",
                                    "Belowground Very Fast DOM", "Belowground Fast DOM", "Belowground Slow DOM",
                                    "Softwood Branch Snag", "Softwood Stem Snag",
                                    "Hardwood Branch Snag", "Hardwood Stem Snag"), 
                                  crossSF)))
numBiomassStocks <- length(biomassStocks)
numDOMStocks <- length(DOMStocks)

# SF Flow Pathways
flowPathways = datasheet(myScenario, name="stsimsf_FlowPathway", empty=F, optional=T) %>% 
  mutate_if(is.factor, as.character)

# Identify growth, biomass transfer, emission, decay, and DOM transfer flows
growthFlows <- flowPathways[flowPathways$FromStockTypeID == crossSF("Atmosphere")]
emissionFlows <- flowPathways[flowPathways$ToStockTypeID == crossSF("Atmosphere"),]
biomassTurnoverFlows <- flowPathways[(flowPathways$FromStockTypeID %in% biomassStocks & flowPathways$ToStockTypeID %in% DOMStocks),]
DOMTransferFlows <- distinct(rbind(flowPathways[flowPathways$FromStockTypeID==crossSF("Aboveground Slow DOM") & flowPathways$ToStockTypeID == crossSF("Belowground Slow DOM"),],
                                   flowPathways[flowPathways$FromStockTypeID==crossSF("Softwood Stem Snag") & flowPathways$ToStockTypeID == crossSF("Aboveground Medium DOM"),],
                                   flowPathways[flowPathways$FromStockTypeID==crossSF("Softwood Branch Snag") & flowPathways$ToStockTypeID == crossSF("Aboveground Fast DOM"),],
                                   flowPathways[flowPathways$FromStockTypeID==crossSF("Hardwood Stem Snag") & flowPathways$ToStockTypeID == crossSF("Aboveground Medium DOM"),],
                                   flowPathways[flowPathways$FromStockTypeID==crossSF("Hardwood Branch Snag") & flowPathways$ToStockTypeID == crossSF("Aboveground Fast DOM"),]))
decayFlows <- rbind(flowPathways[(flowPathways$FromStockTypeID %in% DOMStocks & flowPathways$ToStockTypeID %in% DOMStocks) & (!(flowPathways$FlowTypeID %in% DOMTransferFlows$FlowTypeID)),])

####################################################
# CBM parameters that were not in the CBM database #
####################################################
# DOM Pool ID - "SoilPoolID" taken from CBM User manual Appendix 4 (Kull et al. 2016) - Not found in CMB database
DOMPoolID <- data.frame(CBMStock=c("Aboveground Very Fast DOM", "Belowground Very Fast DOM", "Aboveground Fast DOM", "Belowground Fast DOM", 
                                   "Aboveground Medium DOM", "Aboveground Slow DOM", "Belowground Slow DOM", "Softwood Stem Snag", "Softwood Branch Snag",
                                   "Hardwood Stem Snag", "Hardwood Branch Snag", "Black Carbon", "Peat"), 
                        SoilPoolID=c(0:12))
crosswalkStock <- merge(crosswalkStock, DOMPoolID, all=T)

# Get biomass turnover Proportions (not found in CBM database), taken from Kurtz et al. 2009
proportionMerchantableToSnag <- 1
proportionFineRootsToAGVeryFast <- 0.5
proportionFineRootsToBGVeryFast <- 0.5
proportionCoarseRootsToAGFast <- 0.5
proportionCoarseRootsToBGFast <- 0.5

stateAttributesNetGrowthMaster = datasheet(myScenario, name="stsim_StateAttributeValue", empty = T, optional = T)
flowMultiplierMaster = datasheet(myScenario, name="stsimsf_FlowMultiplier", empty = T, optional = T)
grossMerchantableVolume = datasheet(myScenario, name = "stsimcbmcfs3_MerchantableVolumeCurve")

crosswalkDisturbance = datasheet(myScenario, name = "stsimcbmcfs3_CrosswalkDisturbance")

# Loop over all entries in crosswalkStratumState
# Set up variable to accumulate during the loop
pathways_all <- c()
final_pathways_df <- data.frame()

for(i in 1: nrow(crosswalkStratumState)){
  #i<-1
  ####################################
  # CBM parameters from CBM Database # 
  ####################################
  # Connect to CBM-CFS3 "ArchiveIndex_Beta_Install.mdb"
  CBMdatabase <- odbcDriverConnect(paste0("Driver={Microsoft Access Driver (*.mdb, *.accdb)};DBQ=", CBMDatabase))
  
  # Get Admin Boundary ID
  adminBoundaryTable <- sqlFetch(CBMdatabase, "tblAdminBoundaryDefault")
  adminBoundaryID <- adminBoundaryTable$AdminBoundaryID[adminBoundaryTable$AdminBoundaryName == as.character(crosswalkStratumState$AdminBoundaryID[i])]
  
  # Get Ecological Boundary ID
  ecoBoundaryTable <- sqlFetch(CBMdatabase, "tblEcoBoundaryDefault")
  ecoBoundaryID <- ecoBoundaryTable$EcoBoundaryID[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])]
  
  # Get Species and Forest Type IDs
  speciesTypeTable <- sqlFetch(CBMdatabase, "tblSpeciesTypeDefault")
  speciesTypeID <- speciesTypeTable$SpeciesTypeID[speciesTypeTable$SpeciesTypeName == as.character(crosswalkStratumState$SpeciesTypeID[i])]
  forestTypeID <- speciesTypeTable$ForestTypeID[speciesTypeTable$SpeciesTypeID == speciesTypeID]
  
  # Get Forest Type Name
  forestTypeTable <- sqlFetch(CBMdatabase, "tblForestTypeDefault")
  ForestType <- as.character(forestTypeTable$ForestTypeName[forestTypeTable$ForestTypeID == forestTypeID])
  
  # Get Spatial Planning Unit ID (SPUID) from adminBoundary and ecoBoundary
  SPUTable <- sqlFetch(CBMdatabase, "tblSPUDefault")
  SPUID <- SPUTable$SPUID[SPUTable$AdminBoundaryID==adminBoundaryID & SPUTable$EcoBoundaryID==ecoBoundaryID]
  
  # Throw error if SPUID is empty
  if(is.na(SPUID) || is.null(SPUID) || length(SPUID) == 0){
    stop("SPUID is of length 0 or is NA or null")
  }
  
  # Get Stratums and stateclass IDs
  the_stratum <- crosswalkStratumState$StratumID[i]
  the_secondarystratum <- crosswalkStratumState$SecondaryStratumID[i]
  the_class <- crosswalkStratumState$StateClassID[i]
  
  # Get biomass expansion factors
  biomassExpansionTable <- sqlFetch(CBMdatabase,"tblBioTotalStemwoodForestTypeDefault")
  
  # Get biomass to carbon multipliers
  biomassComponentTable <- sqlFetch(CBMdatabase,"tblBiomassComponent")
  biomassToCarbonTable <- sqlFetch(CBMdatabase,"tblBiomassToCarbonDefault")
  biomassToCarbonTable <- merge.data.frame(biomassToCarbonTable, biomassComponentTable)
  
  # Decay multipliers
  # Temperature modifier parameters
  climateTable <- sqlFetch(CBMdatabase,"tblClimateDefault")
  # There are 2 reference years but they seem to have the same values, I'm arbitrarily choosing 1980
  climateRefYear <- 1980
  if (!is.na(crosswalkStratumState$AverageTemperature[i])){
    meanAnnualTemp <- crosswalkStratumState$AverageTemperature[i]
  } else {
    meanAnnualTemp <- climateTable[climateTable$DefaultSPUID==SPUID & climateTable$Year == climateRefYear, "MeanAnnualTemp"]
  }
  # Stand modifier parameters
  # Note that the maxDecayMult in CBM-CFS3 is 1 which makes the StandMod = 1
  # Do not calculate StandMod this round
  # From Kurz et al. 2009: "In CBM-CFS2 the default value for MaxDecayMult was two. In the CBM-CFS3 the value 
  # defaults to one because more recent studies that examined open canopy effects on decomposition indicated 
  # that decomposition rates are not always higher under open canopies and that decomposition rate responses 
  # may be ecosystem specific (Yanai et al., 2000)." 
  maxDecayMult <- ecoBoundaryTable[ecoBoundaryTable$EcoBoundaryID==ecoBoundaryID, "DecayMult"]
  
  # Get DOM parameters
  DOMParametersTable <- sqlFetch(CBMdatabase,"tblDOMParametersDefault")
  DOMParametersTable <- merge(crosswalkStock[crosswalkStock$StockTypeID %in% DOMStocks,], DOMParametersTable)
  DOMParametersTable$TempMod <- exp((meanAnnualTemp - DOMParametersTable$ReferenceTemp)*log(DOMParametersTable$Q10)*0.1)
  if(ForestType=="Softwood"){
    DOMParametersTable <- DOMParametersTable[DOMParametersTable$CBMStock != "Hardwood Stem Snag",]
    DOMParametersTable <- DOMParametersTable[DOMParametersTable$CBMStock != "Hardwood Branch Snag",]
  }
  if(ForestType=="Hardwood"){
    DOMParametersTable <- DOMParametersTable[DOMParametersTable$CBMStock != "Softwood Stem Snag",]
    DOMParametersTable <- DOMParametersTable[DOMParametersTable$CBMStock != "Softwood Branch Snag",]
  }
  DOMDecayTable <- merge(decayFlows, DOMParametersTable, by.x="FromStockTypeID", by.y="StockTypeID")
  DOMEmissionTable <- merge(emissionFlows, DOMParametersTable, by.x="FromStockTypeID", by.y="StockTypeID")
  DOMDecayTable$Multiplier <- (1 - DOMDecayTable$PropToAtmosphere) * DOMDecayTable$OrganicMatterDecayRate * DOMDecayTable$TempMod
  DOMEmissionTable$Multiplier <- DOMEmissionTable$PropToAtmosphere * DOMEmissionTable$OrganicMatterDecayRate * DOMEmissionTable$TempMod
  DOMTable <- rbind(DOMDecayTable, DOMEmissionTable)
  
  # Get DOM transfer rates
  DOMTransferTable <- sqlFetch(CBMdatabase, "tblSlowAGToBGTransferRate")
  transferRateSlowAGToBG <- signif(DOMTransferTable$SlowAGToBGTransferRate,6)
  if(ForestType=="Softwood"){
    transferRateStemSnagToDOM <- signif(ecoBoundaryTable$SoftwoodStemSnagToDOM[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
    transferRateBranchSnagToDOM <- signif(ecoBoundaryTable$SoftwoodBranchSnagToDOM[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
  }
  if(ForestType=="Hardwood"){
    transferRateStemSnagToDOM <- signif(ecoBoundaryTable$HardwoodStemSnagToDOM[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
    transferRateBranchSnagToDOM <- signif(ecoBoundaryTable$HardwoodBranchSnagToDOM[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
  }
  # Get biomass turnover rates
  speciesTurnoverRatesTable <- sqlFetch(CBMdatabase, "tblSpeciesTypeDefault")
  turnoverRates <- speciesTurnoverRatesTable[speciesTurnoverRatesTable$SpeciesTypeName==as.character(crosswalkStratumState$SpeciesTypeID[i]),]
  
  # Get the disturbance matrix information
  DMassociation = sqlFetch(CBMdatabase, "tblDMAssociationDefault")
  DMassociation = DMassociation[DMassociation$DefaultEcoBoundaryID == ecoBoundaryID,]
  
  disturbanceType = sqlFetch(CBMdatabase, "tblDisturbanceTypeDefault")
  disturbanceMatrix <- sqlFetch(CBMdatabase, "tblDM")
  
  dmValuesLookup = sqlFetch(CBMdatabase, "tblDMValuesLookup")
  
  sourceName <- sqlFetch(CBMdatabase, "tblSourceName") %>% rename("DMRow" = "Row")
  sinkName <- sqlFetch(CBMdatabase, "tblSinkName") %>% rename("DMColumn" = "Column")
  
  # Close the database (do not forget this, otherwise you lock access database from editing)
  close(CBMdatabase)
  
  # Disturbance Stuff -----------------------------------------------------------
  
  if ((doDisturbances == T) & (nrow(crosswalkDisturbance)>0)) {
    
    #Need to rename DMassociation DistTypeID column
    names(DMassociation)[1] = "DistTypeID"
    
    df = DMassociation %>%
      left_join(disturbanceType, by="DistTypeID") %>% 
      select(DMID,DistTypeID,DistTypeName) %>%
      left_join(disturbanceMatrix, by="DMID") %>% 
      select(DMID,DistTypeID,DistTypeName,DMStructureID) %>%
      left_join(dmValuesLookup, by="DMID") %>%
      left_join(sourceName, by=c("DMStructureID","DMRow")) %>% 
      rename("Source" = "Description") %>%
      left_join(sinkName, by=c("DMStructureID", "DMColumn")) %>% 
      rename("Sink" = "Description") %>%
      mutate(Source = as.character(Source), Sink = as.character(Sink)) %>% 
      filter(DistTypeName %in% crosswalkDisturbance$DisturbanceTypeID)
    
    # discriminate between hardwood and softwood
    
    opposite <- ifelse(ForestType == "Softwood", "Hardwood", "Softwood")
    
    df_filtered <- df %>% 
      filter(!str_detect(Source, opposite))
    
    sources = data.frame(CBMSource = unique(df_filtered$Source),
                         FromStockID = "")
    
    sinks = data.frame(CBMSink = unique(df_filtered$Sink),
                       ToStockID = "")
    
    transitions = data.frame(DistTypeName = unique(df_filtered$DistTypeName),
                             TransitionTypeID = "")
    
    #d = data.frame(CBMStocks = df_filtered$Source)
    #d1 = data.frame(CBMStocks = df_filtered$Sink)
    #d2 = bind_rows(d,d1)
    #d3 = data.frame(CBMStocks = unique(d2$CBMStocks), LUCASStocks = "")
    
    temp_crosswalkStock = datasheet(myScenario, name = "stsimcbmcfs3_CrosswalkStock")
    
    # temp_crosswalkStock[16,1] <- "Products"
    
    temp_crosswalkDisturbance = datasheet(myScenario, name = "stsimcbmcfs3_CrosswalkDisturbance") %>% 
      mutate_if(is.factor, as.character)
    
    temp_pathways_df = df_filtered %>% left_join(temp_crosswalkStock, by = c("Source" = "CBMStock")) %>% 
      rename("FromStockTypeID"="StockTypeID") %>%
      left_join(temp_crosswalkStock, by = c("Sink" = "CBMStock")) %>% 
      rename("ToStockTypeID"="StockTypeID") %>%
      select(DistTypeName, FromStockTypeID, ToStockTypeID, Proportion) %>%
      mutate_if(is.factor, as.character) %>%
      left_join(temp_crosswalkDisturbance, by = c("DistTypeName" = "DisturbanceTypeID")) %>%
      filter(!is.na(TransitionGroupID)) %>% 
      filter(!is.na(FromStockTypeID)) %>%
      #mutate(FromStockTypeID = ifelse(FromStockTypeID != ToStockTypeID, FromStockTypeID, NA)) %>%
      filter(!is.na(FromStockTypeID)) %>%
      rename("Multiplier" = "Proportion") %>%
      mutate(FlowTypeID = "", Multiplier = round(Multiplier, 4)) %>%
      select(FromStockTypeID, ToStockTypeID, TransitionGroupID, DistTypeName, FlowTypeID, Multiplier) 
    
    head(temp_pathways_df)
    
    pathways <- temp_pathways_df %>% 
      mutate(left = cut_label(FromStockTypeID, "right"), 
             right = cut_label(ToStockTypeID, "right"), 
             PathwayType = paste0(DistTypeName, ": ", left, " -> ", right)) %>% 
      pull(PathwayType)
    
    pathways_all <- unique(c(pathways_all, pathways))
    
    temp_pathways_df_clean <- temp_pathways_df %>% mutate(FlowTypeID = pathways) %>% 
      mutate(FromStratumID = the_stratum, # ToStratumID = the_stratum, 
             FromSecondaryStratumID = the_secondarystratum, #ToSecondaryStratumID = the_secondarystratum,
             FromStateClassID = the_class#, ToStateClassID = the_class
      ) %>% 
      select(-DistTypeName) %>% 
      filter(FromStockTypeID != ToStockTypeID)
    
    final_pathways_df <- bind_rows(final_pathways_df, temp_pathways_df_clean)
    
    #write.csv(temp_pathways_df, file = "FlowPathways.csv")
    
  }
  
  # Disturbance Stuff -----------------------------------------------------------
  
  # Get biomass turnover Proportions (not found in CBM database), taken from Kurtz et al. 2009
  if(ForestType == "Softwood") proportionFoliageToAGVeryFast <- 1
  if(ForestType == "Hardwood") proportionFoliageToAGVeryFast <- 1
  
  ###
  # TODO: put biomass expansion factor stuff in here...
  
  #####################################################
  # Biomass Turnover and DOM Decay and Transfer rates #
  #####################################################
  # DOM transfer rates
  DOMTransferFlows[DOMTransferFlows$FromStockTypeID==crossSF("Aboveground Slow DOM") & DOMTransferFlows$ToStockTypeID == crossSF("Belowground Slow DOM"), "Multiplier"] <- transferRateSlowAGToBG
  
  if(ForestType == "Softwood"){
    DOMTransferFlows[DOMTransferFlows$FromStockTypeID==crossSF("Softwood Stem Snag") & DOMTransferFlows$ToStockTypeID == crossSF("Aboveground Medium DOM"), "Multiplier"] <- transferRateStemSnagToDOM
    DOMTransferFlows[DOMTransferFlows$FromStockTypeID==crossSF("Softwood Branch Snag") & DOMTransferFlows$ToStockTypeID == crossSF("Aboveground Fast DOM"), "Multiplier"] <- transferRateBranchSnagToDOM
  }
  if(ForestType == "Hardwood"){
    DOMTransferFlows[DOMTransferFlows$FromStockTypeID==crossSF("Hardwood Stem Snag") & DOMTransferFlows$ToStockTypeID == crossSF("Aboveground Medium DOM"), "Multiplier"] <- transferRateStemSnagToDOM
    DOMTransferFlows[DOMTransferFlows$FromStockTypeID==crossSF("Hardwood Branch Snag") & DOMTransferFlows$ToStockTypeID == crossSF("Aboveground Fast DOM"), "Multiplier"] <- transferRateBranchSnagToDOM
  }
  
  DOMTable <- rbind(DOMTable[,names(DOMTransferFlows)], DOMTransferFlows)
  
  # Biomass turnover rates
  turnOverRateStemAnnual <- signif(ecoBoundaryTable$StemAnnualTurnOverRate[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
  turnOverRateFineRootsAGVeryFast <- signif(turnoverRates$FineRootTurnPropSlope, 6)
  turnOverRateFineRootsBGVeryFast <- signif(turnoverRates$FineRootTurnPropSlope, 6)
  turnOverRateCoarseRootsAGFast <- signif(turnoverRates$CoarseRootTurnProp, 6)
  turnOverRateCoarseRootsBGFast <- signif(turnoverRates$CoarseRootTurnProp, 6)
  if(ForestType == "Softwood"){
    turnOverRateBranch <- signif(ecoBoundaryTable$SoftwoodBranchTurnOverRate[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
    turnOverRateFoliage <- signif(ecoBoundaryTable$SoftwoodFoliageFallRate[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
  }
  if(ForestType == "Hardwood"){
    turnOverRateBranch <- signif(ecoBoundaryTable$HardwoodBranchTurnOverRate[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
    turnOverRateFoliage <- signif(ecoBoundaryTable$HardwoodFoliageFallRate[ecoBoundaryTable$EcoBoundaryName == as.character(crosswalkStratumState$EcoBoundaryID[i])],6)
  }
  
  # Turnover proportions
  proportionOtherToBranchSnag <- signif(turnoverRates$BranchesToBranchSnag,6)
  proportionOtherToAGFast <- 1 - proportionOtherToBranchSnag
  
  biomassTurnoverTable <- biomassTurnoverFlows
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Merchantable")] <- turnOverRateStemAnnual * proportionMerchantableToSnag 
  if(ForestType == "Softwood") biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Softwood Branch Snag")] <- turnOverRateBranch * proportionOtherToBranchSnag
  if(ForestType == "Hardwood") biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Hardwood Branch Snag")] <- turnOverRateBranch * proportionOtherToBranchSnag
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Fast DOM")] <- turnOverRateBranch * proportionOtherToAGFast
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Foliage")] <- turnOverRateFoliage * proportionFoliageToAGVeryFast 
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Fine root") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Very Fast DOM")] <- turnOverRateFineRootsAGVeryFast * proportionFineRootsToAGVeryFast
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Fine root") & biomassTurnoverTable$ToStockTypeID == crossSF("Belowground Very Fast DOM")] <- turnOverRateFineRootsBGVeryFast * proportionFineRootsToBGVeryFast
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Coarse root") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Fast DOM")] <- turnOverRateCoarseRootsAGFast * proportionCoarseRootsToAGFast
  biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Coarse root") & biomassTurnoverTable$ToStockTypeID == crossSF("Belowground Fast DOM")] <- turnOverRateCoarseRootsBGFast * proportionCoarseRootsToBGFast
  
  ########################################################
  # Calculate net growth based on mass-balance equations #
  ########################################################
  
  
  # Original approach using CBM Output. Remove eventually...
  if(useCBMAgeVsCarbonCurves==T){
    stateAttributeValues <- datasheet(myScenario, "stsim_StateAttributeValue", empty=FALSE, optional=TRUE)
    stateAttributeValuesWide <- spread(stateAttributeValues, key="StateAttributeTypeID", value = "Value")
    carbonInitialConditions <- datasheet(myScenario, "stsimsf_InitialStockNonSpatial", empty=FALSE, optional=TRUE)
    
    if (SSIsWildCard){
      volumeToCarbon <- filter(stateAttributeValuesWide, StratumID == crosswalkStratumState$StratumID[i] & StateClassID == crosswalkStratumState$StateClassID[i])
    } else {
      volumeToCarbon <- filter(stateAttributeValuesWide, StratumID == crosswalkStratumState$StratumID[i] & SecondaryStratumID == crosswalkStratumState$SecondaryStratumID[i] & StateClassID == crosswalkStratumState$StateClassID[i])
    }
    volumeToCarbon$c_m <- volumeToCarbon[, as.character(carbonInitialConditions$StateAttributeTypeID[carbonInitialConditions$StockTypeID == crossSF("Merchantable")])]
    volumeToCarbon$c_foliage <- volumeToCarbon[, as.character(carbonInitialConditions$StateAttributeTypeID[carbonInitialConditions$StockTypeID == crossSF("Foliage")])]
    volumeToCarbon$c_other <- volumeToCarbon[, as.character(carbonInitialConditions$StateAttributeTypeID[carbonInitialConditions$StockTypeID == crossSF("Other")])]
    volumeToCarbon$c_fineroots <- volumeToCarbon[, as.character(carbonInitialConditions$StateAttributeTypeID[carbonInitialConditions$StockTypeID == crossSF("Fine root")])]
    volumeToCarbon$c_coarseroots <- volumeToCarbon[, as.character(carbonInitialConditions$StateAttributeTypeID[carbonInitialConditions$StockTypeID == crossSF("Coarse root")])]
    
  }
  
  # Approach using equations from Boudewyn et al. 2007 (aboveground) and Li et al 2003 (belowground). 
  if(useCBMAgeVsCarbonCurves==F){
    
    # Total stem wood biomass estimation
    A <- biomassExpansionTable$A[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID] 
    B <- biomassExpansionTable$B[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID] 
    
    # Nonmerchantable expansion factor
    a_nonmerch <- biomassExpansionTable$a_nonmerch[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID] 
    b_nonmerch <- biomassExpansionTable$b_nonmerch[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID] 
    k_nonmerch <- biomassExpansionTable$k_nonmerch[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID] 
    cap_nonmerch <- biomassExpansionTable$cap_nonmerch[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID] 
    
    # Sapling expansion factor
    a_sap <- biomassExpansionTable$a_sap[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    b_sap <- biomassExpansionTable$b_sap[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    k_sap <- biomassExpansionTable$k_sap[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    cap_sap <- biomassExpansionTable$cap_sap[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    
    # Stem bark proportion
    a1 <- biomassExpansionTable$a1[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    a2 <- biomassExpansionTable$a2[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    a3 <- biomassExpansionTable$a3[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    
    # Branches proportion
    b1 <- biomassExpansionTable$b1[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    b2 <- biomassExpansionTable$b2[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    b3 <- biomassExpansionTable$b3[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    
    # Foliage proportion
    c1 <- biomassExpansionTable$c1[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    c2 <- biomassExpansionTable$c2[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    c3 <- biomassExpansionTable$c3[biomassExpansionTable$DefaultSPUID==SPUID & biomassExpansionTable$DefaultForestTypeID==forestTypeID]
    
    # Set up dataframe to hold results
    # temporary load merchantable volume from csv
    # linear curve only for now
    
    if (SSIsWildCard){
      grossMerchantableVolumeFiltered = filter(grossMerchantableVolume, StratumID == crosswalkStratumState$StratumID[i] & StateClassID == crosswalkStratumState$StateClassID[i])
    } else {
      grossMerchantableVolumeFiltered = filter(grossMerchantableVolume, StratumID == crosswalkStratumState$StratumID[i] & SecondaryStratumID == crosswalkStratumState$SecondaryStratumID[i] & StateClassID == crosswalkStratumState$StateClassID[i])
    }
    volumeToCarbon <- data.frame(age = grossMerchantableVolumeFiltered$Age, volume = grossMerchantableVolumeFiltered$MerchantableVolume)
    volumeToCarbon$StratumID = crosswalkStratumState$StratumID[i]
    volumeToCarbon$SecondaryStratumID = crosswalkStratumState$SecondaryStratumID[i]
    volumeToCarbon$StateClassID = crosswalkStratumState$StateClassID[i]
    
    
    # Total stem wood biomass/ha for live, merchantable size trees
    # b_m = total stem wood biomass of merchantable-sized live trees (biomass includes stumps and tops), in metric tonnes per ha
    volumeToCarbon$b_m <- A * volumeToCarbon$volume ^ B
    
    # Total stem wood biomass/ha for live, non-merchantable size trees
    # Nonmerchantable expansion factor
    volumeToCarbon$nonmerchfactor <- k_nonmerch + a_nonmerch * volumeToCarbon$b_m ^ b_nonmerch
    # b_nm = stem wood biomass of live, merchantable and nonmerchantable-sized trees (tonnes/ha)
    volumeToCarbon$b_nm <- volumeToCarbon$nonmerchfactor * volumeToCarbon$b_m
    # b_n = stem wood biomass of live, nonmerchantable-sized trees (tonnes/ha)
    volumeToCarbon$b_n <- (volumeToCarbon$nonmerchfactor * volumeToCarbon$b_m) - volumeToCarbon$b_m
    
    # Total stem wood biomass/ha for live sapling size trees
    #Sapling expansion factor
    volumeToCarbon$saplingfactor <- k_sap + a_sap * (volumeToCarbon$b_nm ^ b_sap)
    # b_s = stem wood biomass of live, sapling-sized trees (tonnes/ha)
    volumeToCarbon$b_s <- (volumeToCarbon$saplingfactor * volumeToCarbon$b_nm) - volumeToCarbon$b_nm
    
    # Total stemwood of all live trees
    volumeToCarbon$b_sw <- volumeToCarbon$b_m + volumeToCarbon$b_n + volumeToCarbon$b_s
    
    # Compute proportions
    volumeToCarbon$denominator <- (1 + exp(a1 + a2 * volumeToCarbon$volume + a3 * log(volumeToCarbon$volume + 5)) 
                                   + exp(b1 + b2 * volumeToCarbon$volume + b3 * log(volumeToCarbon$volume + 5)) 
                                   + exp(c1 + c2 * volumeToCarbon$volume + c3 * log(volumeToCarbon$volume + 5)))
    
    # Stem wood proportion
    volumeToCarbon$p_stemwood <- 1 / volumeToCarbon$denominator  
    
    # Stem bark proportion  
    volumeToCarbon$p_bark <- exp(a1 + a2 * volumeToCarbon$volume + a3 * log(volumeToCarbon$volume + 5)) / volumeToCarbon$denominator
    
    # Branches proportion
    volumeToCarbon$p_branches <- exp(b1 + b2 * volumeToCarbon$volume + b3 * log(volumeToCarbon$volume + 5)) / volumeToCarbon$denominator
    
    # Foliage proportion
    volumeToCarbon$p_foliage <- exp(c1 + c2 * volumeToCarbon$volume + c3 * log(volumeToCarbon$volume + 5)) / volumeToCarbon$denominator
    
    #Total tree biomass/ha live
    volumeToCarbon$b <- volumeToCarbon$b_sw / volumeToCarbon$p_stemwood
    
    # Biomass based on b (total biomass of live trees)
    volumeToCarbon$b_bark <- volumeToCarbon$b * volumeToCarbon$p_bark
    volumeToCarbon$b_branches <- volumeToCarbon$b * volumeToCarbon$p_branches
    volumeToCarbon$b_foliage <- volumeToCarbon$b * volumeToCarbon$p_foliage
    volumeToCarbon$b_other <- volumeToCarbon$b_bark + volumeToCarbon$b_branches + volumeToCarbon$b_n + volumeToCarbon$b_s
    
    ## Biomass to carbon
    isSoftwood <- if(ForestType == "Softwood") 1 else 0
    volumeToCarbon$c_aboveground <- volumeToCarbon$b * biomassToCarbonTable[biomassToCarbonTable$BiomassComponentName=="Other biomass component" & 
                                                                              biomassToCarbonTable$Softwood==isSoftwood, "Multiplier"]
    volumeToCarbon$c_other <- volumeToCarbon$b_other * biomassToCarbonTable[biomassToCarbonTable$BiomassComponentName=="Other biomass component" & 
                                                                              biomassToCarbonTable$Softwood==isSoftwood, "Multiplier"]
    volumeToCarbon$c_foliage <- volumeToCarbon$b_foliage * biomassToCarbonTable[biomassToCarbonTable$BiomassComponentName=="Foliage biomass component" & 
                                                                                  biomassToCarbonTable$Softwood==isSoftwood, "Multiplier"]
    volumeToCarbon$c_m <- volumeToCarbon$b_m * biomassToCarbonTable[biomassToCarbonTable$BiomassComponentName=="Merchantable biomass component" & 
                                                                      biomassToCarbonTable$Softwood==isSoftwood, "Multiplier"]
    
    #Replace NoN values with 0's
    is.nan.data.frame <- function(x)
      do.call(cbind, lapply(x, is.nan))
    
    volumeToCarbon[is.nan.data.frame(volumeToCarbon)] <- 0
    
    # Parameters from Li et al. 2003
    if(isSoftwood) {
      volumeToCarbon$b_roots <- 0.2222 * volumeToCarbon$b
    } 
    else {
      volumeToCarbon$b_roots <- 1.576 * volumeToCarbon$b ^ 0.615
    }
    volumeToCarbon$p_fineroots <- 0.072 + 0.354 * exp(-0.060 * volumeToCarbon$b_roots)
    volumeToCarbon$b_fineroots <- volumeToCarbon$p_fineroots * volumeToCarbon$b_roots
    volumeToCarbon$b_coarseroots <- volumeToCarbon$b_root - volumeToCarbon$b_fineroots
    # Add in hardwood equation
    
    ## Biomass to carbon
    isSoftwood <- if(ForestType == "Softwood") 1 else 0
    volumeToCarbon$c_fineroots <- volumeToCarbon$b_fineroots * biomassToCarbonTable[biomassToCarbonTable$BiomassComponentName=="Fine root biomass component" & 
                                                                                      biomassToCarbonTable$Softwood==isSoftwood, "Multiplier"]
    volumeToCarbon$c_coarseroots <- volumeToCarbon$b_coarseroots * biomassToCarbonTable[biomassToCarbonTable$BiomassComponentName=="Coarse root biomass component" & 
                                                                                          biomassToCarbonTable$Softwood==isSoftwood, "Multiplier"]
    volumeToCarbon$c_belowground <- volumeToCarbon$c_fineroots + volumeToCarbon$c_coarseroots
    
  }
  
  volumeToCarbon$c_m1 <- c(volumeToCarbon$c_m[2:nrow(volumeToCarbon)], NA)
  volumeToCarbon$c_foliage1 <- c(volumeToCarbon$c_foliage[2:nrow(volumeToCarbon)], NA)
  volumeToCarbon$c_other1 <- c(volumeToCarbon$c_other[2:nrow(volumeToCarbon)], NA)
  volumeToCarbon$c_fineroots1 <- c(volumeToCarbon$c_fineroots[2:nrow(volumeToCarbon)], NA)
  volumeToCarbon$c_coarseroots1 <- c(volumeToCarbon$c_coarseroots[2:nrow(volumeToCarbon)], NA)
  
  # Growth happens after biomass transfer
  if(ForestType == "Softwood") volumeToCarbon$g_m <- volumeToCarbon$c_m1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Merchantable") & biomassTurnoverTable$ToStockTypeID == crossSF("Softwood Stem Snag")]) * volumeToCarbon$c_m
  if(ForestType == "Hardwood") volumeToCarbon$g_m <- volumeToCarbon$c_m1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Merchantable") & biomassTurnoverTable$ToStockTypeID == crossSF("Hardwood Stem Snag")]) * volumeToCarbon$c_m
  volumeToCarbon$g_foliage <- volumeToCarbon$c_foliage1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Foliage") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Very Fast DOM")]) * volumeToCarbon$c_foliage
  if(ForestType == "Softwood") volumeToCarbon$g_other <- volumeToCarbon$c_other1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Fast DOM")] - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Softwood Branch Snag")]) * volumeToCarbon$c_other
  if(ForestType == "Hardwood") volumeToCarbon$g_other <- volumeToCarbon$c_other1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Fast DOM")] - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Other") & biomassTurnoverTable$ToStockTypeID == crossSF("Hardwood Branch Snag")]) * volumeToCarbon$c_other
  volumeToCarbon$g_fineroots <- volumeToCarbon$c_fineroots1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Fine root") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Very Fast DOM")]  - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Fine root") & biomassTurnoverTable$ToStockTypeID == crossSF("Belowground Very Fast DOM")]) * volumeToCarbon$c_fineroots
  volumeToCarbon$g_coarseroots <- volumeToCarbon$c_coarseroots1 - (1 - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Coarse root") & biomassTurnoverTable$ToStockTypeID == crossSF("Aboveground Fast DOM")]  - biomassTurnoverTable$Multiplier[biomassTurnoverTable$FromStockTypeID == crossSF("Coarse root") & biomassTurnoverTable$ToStockTypeID == crossSF("Belowground Fast DOM")]) * volumeToCarbon$c_coarseroots
  volumeToCarbon$g_all <- volumeToCarbon$g_m + volumeToCarbon$g_foliage + volumeToCarbon$g_other + volumeToCarbon$g_fineroots + volumeToCarbon$g_coarseroots
  volumeToCarbon <- volumeToCarbon[1:(nrow(volumeToCarbon)-1),]
  
  #Replace NaN values with 0's
  is.nan.data.frame <- function(x){
    do.call(cbind, lapply(x, is.nan))
  }
  
  volumeToCarbon[is.nan.data.frame(volumeToCarbon)] <- 0
  volumeToCarbon <- volumeToCarbon %>% mutate_if(is.factor, as.character)
  volumeToCarbon <- cbind(volumeToCarbon[,c("StratumID", "SecondaryStratumID", "StateClassID")], do.call(data.frame,lapply(volumeToCarbon[,!(names(volumeToCarbon) %in% c("StratumID", "SecondaryStratumID", "StateClassID"))], function(x) replace(x, is.infinite(x),0))))
  
  #######################
  # STSim-SF datasheets #
  #######################
  # State Attribute Values for net growth based on mass-balance equations
  stateAttributesNetGrowth = datasheet(myScenario, name="stsim_StateAttributeValue", empty = T, optional = T)
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "StratumID"] <- volumeToCarbon$StratumID[1:nrow(volumeToCarbon)]
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "SecondaryStratumID"] <- volumeToCarbon$SecondaryStratumID[1:nrow(volumeToCarbon)]
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "StateClassID"] <- volumeToCarbon$StateClassID[1:nrow(volumeToCarbon)]
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "StateAttributeTypeID"] <- rep(as.character(flowPathways$StateAttributeTypeID[(flowPathways$FromStockTypeID==crossSF("Atmosphere") & flowPathways$ToStockTypeID==crossSF("Merchantable"))]), nrow(volumeToCarbon))
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "AgeMin"] <- volumeToCarbon$AgeMin[1:nrow(volumeToCarbon)]
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "AgeMax"] <- volumeToCarbon$AgeMax[1:nrow(volumeToCarbon)]
  stateAttributesNetGrowth[1:nrow(volumeToCarbon), "Value"] <- volumeToCarbon$g_all[1:nrow(volumeToCarbon)]
  stateAttributesNetGrowth[nrow(volumeToCarbon), "AgeMax"] <- NA
  
  stateAttributesNetGrowthMaster = rbind(stateAttributesNetGrowth, stateAttributesNetGrowthMaster)
  
  # SF Flow Pathways
  # Flow Multilpiers for biomass net growth based on volume-to-carbon proportions 
  flowMultiplierNetGrowth <- datasheet(myScenario, name="stsimsf_FlowMultiplier", empty = T, optional = T)
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks), "StratumID"] <- crosswalkStratumState$StratumID[i]
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks), "SecondaryStratumID"] <- crosswalkStratumState$SecondaryStratumID[i]
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks),"StateClassID"] <- crosswalkStratumState$StateClassID[i]
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks), "AgeMin"] <- rep(volumeToCarbon$AgeMin[1:nrow(volumeToCarbon)], numBiomassStocks)
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks), "AgeMax"] <- rep(stateAttributesNetGrowth$AgeMax, numBiomassStocks)
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks), "FlowGroupID"] <- c(rep(paste0(as.character(flowPathways$FlowTypeID[(flowPathways$FromStockTypeID==crossSF("Atmosphere") & flowPathways$ToStockTypeID==crossSF("Merchantable"))])," [Type]"), nrow(volumeToCarbon)),
                                                                                         rep(paste0(as.character(flowPathways$FlowTypeID[(flowPathways$FromStockTypeID==crossSF("Atmosphere") & flowPathways$ToStockTypeID==crossSF("Other"))]), " [Type]"),nrow(volumeToCarbon)),
                                                                                         rep(paste0(as.character(flowPathways$FlowTypeID[(flowPathways$FromStockTypeID==crossSF("Atmosphere") & flowPathways$ToStockTypeID==crossSF("Foliage"))]), " [Type]"), nrow(volumeToCarbon)),
                                                                                         rep(paste0(as.character(flowPathways$FlowTypeID[(flowPathways$FromStockTypeID==crossSF("Atmosphere") & flowPathways$ToStockTypeID==crossSF("Fine root"))]), " [Type]"), nrow(volumeToCarbon)),
                                                                                         rep(paste0(as.character(flowPathways$FlowTypeID[(flowPathways$FromStockTypeID==crossSF("Atmosphere") & flowPathways$ToStockTypeID==crossSF("Coarse root"))]), " [Type]"),  nrow(volumeToCarbon)))
  flowMultiplierNetGrowth[1:(nrow(volumeToCarbon)*numBiomassStocks), "Value"] <- c(volumeToCarbon$g_m[1:nrow(volumeToCarbon)] / volumeToCarbon$g_all[1:nrow(volumeToCarbon)],
                                                                                   volumeToCarbon$g_other[1:nrow(volumeToCarbon)] / volumeToCarbon$g_all[1:nrow(volumeToCarbon)],
                                                                                   volumeToCarbon$g_foliage[1:nrow(volumeToCarbon)] / volumeToCarbon$g_all[1:nrow(volumeToCarbon)],
                                                                                   volumeToCarbon$g_fineroots[1:nrow(volumeToCarbon)] / volumeToCarbon$g_all[1:nrow(volumeToCarbon)],
                                                                                   volumeToCarbon$g_coarseroots[1:nrow(volumeToCarbon)] / volumeToCarbon$g_all[1:nrow(volumeToCarbon)])
  #flowMultiplierNetGrowth[flowMultiplierNetGrowth$AgeMin == volumeToCarbon$AgeMin[nrow(volumeToCarbon)], "AgeMax"] <- NA
  #flowMultiplierNetGrowth[is.nan.data.frame(flowMultiplierNetGrowth)] <- 0
  
  #Flow Pathways for biomass turnover rates and DOM transfer and decay rates
  flowPathwayTable <- rbind(biomassTurnoverTable, DOMTable[,names(biomassTurnoverTable)])
  flowMultiplierTurnoverTransferDecayEmission <- datasheet(myScenario, name="stsimsf_FlowMultiplier", empty=T, optional=T)
  flowMultiplierTurnoverTransferDecayEmission[1:nrow(flowPathwayTable), "StratumID"] <- crosswalkStratumState$StratumID[i]
  flowMultiplierTurnoverTransferDecayEmission[1:nrow(flowPathwayTable), "SecondaryStratumID"] <- crosswalkStratumState$SecondaryStratumID[i]
  flowMultiplierTurnoverTransferDecayEmission[1:nrow(flowPathwayTable), "StateClassID"] <- crosswalkStratumState$StateClassID[i]
  flowMultiplierTurnoverTransferDecayEmission[1:nrow(flowPathwayTable), "FlowGroupID"] = paste0(flowPathwayTable$FlowTypeID," [Type]")
  flowMultiplierTurnoverTransferDecayEmission[1:nrow(flowPathwayTable), "Value"] = flowPathwayTable$Multiplier
  
  # Combine all flow multipliers
  flowMultiplierAll <- rbind(flowMultiplierNetGrowth, flowMultiplierTurnoverTransferDecayEmission)
  flowMultiplierMaster <- rbind(flowMultiplierAll,flowMultiplierMaster)
  
  
}

# Assemble final flowtype at project level scope
flowtypes <- datasheet(myProject, "stsimsf_FlowType") %>% 
  mutate_if(is.factor, as.character) %>% 
  bind_rows(data.frame(Name = pathways_all, stringsAsFactors = F)) %>% 
  unique()
saveDatasheet(myProject, flowtypes, name = "stsimsf_FlowType")

# Save flow pathways to scenario
final_pathways_df_unique <- final_pathways_df %>% 
  mutate_if(is.factor, as.character) %>% 
  bind_rows(flowPathways) %>% 
  unique()
saveDatasheet(myScenario, final_pathways_df_unique, name = "stsimsf_FlowPathway")

saveDatasheet(myScenario, stateAttributesNetGrowthMaster, name = "stsim_StateAttributeValue", append = TRUE)
saveDatasheet(myScenario, flowMultiplierMaster, name="stsimsf_FlowMultiplier", append=T)


