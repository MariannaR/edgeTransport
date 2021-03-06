#' Generate EDGE-Transport Input Data for the REMIND model.
#'
#' Run this script to prepare the input data for EDGE in EDGE-friendly units and regional aggregation
#' @param input_folder folder hosting raw data
#' @param output_folder folder hosting REMIND input files
#' @param EDGE_scenario EDGE transport scenario specifier
#' @param REMIND_scenario SSP scenario
#' @param saveRDS optional saving of intermediate RDS files
#'
#' @return generated EDGE-transport input data
#' @author Alois Dirnaichner, Marianna Rottoli
#' @import data.table
#' @import mrremind
#' @import edgeTrpLib
#' @importFrom madrat setConfig
#' @importFrom magclass getSets
#' @export


generateEDGEdata <- function(input_folder, output_folder,
                             EDGE_scenario, REMIND_scenario="SSP2",
                             saveRDS=FALSE){

  scenario <- scenario_name <- vehicle_type <- type <- `.` <- CountryCode <- RegionCode <- NULL
  
  setConfig(forcecache = TRUE)

  levelNpath <- function(fname, N){
    path <- file.path(output_folder, REMIND_scenario, EDGE_scenario, paste0("level_", N))
    if(!dir.exists(path)){
      dir.create(path, recursive = T)
    }
    return(file.path(path, fname))
  }

  level0path <- function(fname){
    levelNpath(fname, 0)
  }

  level1path <- function(fname){
    levelNpath(fname, 1)
  }

  level2path <- function(fname){
    levelNpath(fname, 2)
  }


  years <- c(1990,
             seq(2005, 2060, by = 5),
             seq(2070, 2110, by = 10),
             2130, 2150)
  ## load mappings
  REMIND2ISO_MAPPING = fread(system.file("extdata", "regionmappingH12.csv", package = "edgeTransport"))[, .(iso = CountryCode,region = RegionCode)]
  EDGEscenarios = fread(system.file("extdata", "EDGEscenario_description.csv", package = "edgeTransport"))
  GCAM2ISO_MAPPING = fread(system.file("extdata", "iso_GCAM.csv", package = "edgeTransport"))
  EDGE2teESmap = fread(system.file("extdata", "mapping_EDGE_REMIND_transport_categories.csv", package = "edgeTransport"))
  EDGE2CESmap = fread(system.file("extdata", "mapping_CESnodes_EDGE.csv", package = "edgeTransport"))
  
  ## load specific transport switches
  EDGEscenarios <- EDGEscenarios[scenario_name == EDGE_scenario]

  merge_traccs <- EDGEscenarios[options == "merge_traccs", switch]
  print(paste0("You selected the option to include bottom-up data from the TRACCS database to :", merge_traccs))
  inconvenience <- EDGEscenarios[options == "inconvenience", switch]
  print(paste0("You selected the option to express preferences for 4Wheelers in terms of inconvenience costs to:", inconvenience))
  selfmarket_taxes <- EDGEscenarios[options == "selfmarket_taxes", switch]
  print(paste0("You selected self-sustaining market, option Taxes to: ", selfmarket_taxes))
  enhancedtech <- EDGEscenarios[options== "enhancedtech", switch]
  print(paste0("You selected the option to select an optimistic trend of costs/performances of alternative technologies to: ", enhancedtech))
  rebates_febates <- EDGEscenarios[options== "rebates_febates", switch]
  print(paste0("You selected the option to include rebates and ICE costs markup to: ", rebates_febates))
  smartlifestyle <- EDGEscenarios[options== "smartlifestyle", switch]
  print(paste0("You selected the option to include lifestyle changes to: ", smartlifestyle))

  if (EDGE_scenario %in% c("ConvCase", "ConvCaseWise")) {
    techswitch <- "Liquids"
  } else if (EDGE_scenario %in% c("ElecEra", "ElecEraWise")) {
    techswitch <- "BEV"
  } else if (EDGE_scenario %in% c("HydrHype", "HydrHypeWise")) {
    techswitch <- "FCEV"
  } else {
    print("You selected a not allowed scenario. Scenarios allowed are: ConvCase, ConvCaseWise, ElecEra, ElecEraWise, HydrHype, HydrHypeWise")
    quit()
  }

  print(paste0("You selected the ", EDGE_scenario, " transport scenario."))
  print(paste0("You selected the ", REMIND_scenario, " socio-economic scenario."))

  #################################################
  ## LVL 0 scripts
  #################################################
  print("-- Start of level 0 scripts")

  ## function that loads raw data from the GCAM input files and modifies them, to make them compatible with EDGE setup
  ## Final values:
  ## demand for energy services (tech_output): million pkm and tmk
  ## energy intensity (conv_pkm_MJ): MJ/km
  ## load factor (load_factor): passenger per vehicles (passenger demand), ton per vehicles (freight demand)
  ## speed (speed): km/h
  print("-- load GCAM raw data")
  GCAM_data <- lvl0_GCAMraw(input_folder)

  ## function that loads PSI energy intensity for Europe and merges them with GCAM intensities.
  ## Final units:
  ## energy intensity (conv_pkm_MJ): MJ/km
  print("-- merge PSI energy intensity data")
  intensity_PSI_GCAM_data <- lvl0_mergePSIintensity(GCAM_data, input_folder, enhancedtech = enhancedtech, techswitch = techswitch)
  GCAM_data$conv_pkm_mj = intensity_PSI_GCAM_data

  if(saveRDS)
    saveRDS(intensity_PSI_GCAM_data, file = level0path("intensity_PSI_GCAM.RDS"))

  ## function that calculates VOT for each level and logit exponents for each level.
  ## Final units:
  ## Value Of Time (VOT_output): [1990$/km], either pkm (passenger) or tkm (freight)
  print("-- load value-of-time and logit exponents")
  VOT_lambdas=lvl0_VOTandExponents(GCAM_data, REMIND_scenario, input_folder, GCAM2ISO_MAPPING)

  ## function that loads and prepares the non_fuel prices. It also load PSI-based purchase prices for EU.
  ## Final units:
  ## non fuel price (non_energy_cost and non_energy_cost_split): in 1990USD/pkm (1990USD/tkm),
  ## annual mileage (annual_mileage): in vkt/veh/yr (vehicle km traveled per year),
  ## depreciation rate (fcr_veh): [-]
  print("-- load UCD database")
  UCD_output <- lvl0_loadUCD(GCAM_data = GCAM_data, EDGE_scenario = EDGE_scenario, REMIND_scenario = REMIND_scenario, GCAM2ISO_MAPPING = GCAM2ISO_MAPPING,
                            input_folder = input_folder, years = years, enhancedtech = enhancedtech, selfmarket_taxes = selfmarket_taxes, rebates_febates = rebates_febates, techswitch = techswitch)


  ## function that applies corrections to GCAM outdated data. No conversion of units happening.
  print("-- correct tech output")
  correctedOutput <- lvl0_correctTechOutput(GCAM_data,
                                            UCD_output$non_energy_cost,
                                            VOT_lambdas$logit_output)

  GCAM_data[["tech_output"]] = correctedOutput$GCAM_output$tech_output
  GCAM_data[["conv_pkm_mj"]] = correctedOutput$GCAM_output$conv_pkm_mj
  UCD_output$non_energy_cost$non_energy_cost = correctedOutput$NEcost$non_energy_cost
  UCD_output$non_energy_cost$non_energy_cost_split = correctedOutput$NEcost$non_energy_cost_split
  VOT_lambdas$logit_output = correctedOutput$logitexp

  if(saveRDS){
    saveRDS(GCAM_data, file = level0path("GCAM_data.RDS"))
    saveRDS(UCD_output, file = level0path("UCD_output.RDS"))
    saveRDS(VOT_lambdas, file = level0path("logit_exp.RDS"))
  }


  ## produce ISO versions of all files. No conversion of units happening.
  print("-- generate ISO level data")
  iso_data <- lvl0_toISO(
    input_data = GCAM_data,
    VOT_data = VOT_lambdas$VOT_output,
    price_nonmot = VOT_lambdas$price_nonmot,
    UCD_data = UCD_output,
    GCAM2ISO_MAPPING = GCAM2ISO_MAPPING,
    EDGE_scenario = EDGE_scenario,
    REMIND_scenario = REMIND_scenario)

  ## includes demand from the TRACCS-country level data if needed (has to happen on ISO level)
  if (merge_traccs == TRUE) {
    ## function that loads the TRACCS data for Europe.
    ## Final units:
    ## demand (all elements in TRACCS_data): millionkm (tkm and pkm)
    print("-- load EU TRACCS data")
    TRACCS_data <- lvl0_loadTRACCS(input_folder)
    if(saveRDS)
      saveRDS(TRACCS_data, file = level0path("load_TRACCS_data.RDS"))

    ## function that makes the TRACCS database compatible with the GCAM framework.
    ## Final units:
    ## demand for energy services (tech_output): million pkm and tmk
    ## energy intensity (conv_pkm_MJ): MJ/km
    ## load factor (load_factor): passenger per vehicles (passenger demand), ton per vehicles (freight demand)
    print("-- prepare the EU TRACCS database")
    TRACCS_EI_dem_LF <- lvl0_prepareTRACCS(TRACCS_data = TRACCS_data,
                                           GCAM_data = GCAM_data,
                                           intensity = intensity_PSI_GCAM_data,
                                           input_folder = input_folder,
                                           GCAM2ISO_MAPPING = GCAM2ISO_MAPPING)

    print("-- merge the EU TRACCS database (energy intensity, load factors and energy services)")
    iso_data$iso_GCAMdata_results$tech_output <- lvl0_mergeTRACCS(
      TRACCS_data = TRACCS_EI_dem_LF,
      output = iso_data$iso_GCAMdata_results$tech_output)
  }

  if (inconvenience) {
    ## function that calculates the inconvenience cost starting point between 1990 and 2020
    ## Final units:
    ## inconvenience costs (incocost): passenger 1990USD/pkm, freight 1990USD/tkm
    incocost <- lvl0_incocost(annual_mileage = iso_data$iso_UCD_results$annual_mileage_iso,
                              load_factor = iso_data$iso_UCD_results$load_iso,
                              fcr_veh = UCD_output$fcr_veh)
  }


  if(saveRDS){
    saveRDS(iso_data$iso_VOT_results,
            file = level0path("VOT_iso.RDS"))
    saveRDS(iso_data$iso_pricenonmot_results,
            file = level0path("price_nonmot_iso.RDS"))
    saveRDS(iso_data$iso_UCD_results$nec_cost_split_iso,
            file = level0path("UCD_NEC_split_iso.RDS"))
    saveRDS(iso_data$iso_UCD_results$annual_mileage_iso,
            file = level0path("UCD_mileage_iso.RDS"))
    saveRDS(iso_data$iso_UCD_results$nec_iso,
            file = level0path("UCD_NEC_iso.RDS"))
    saveRDS(iso_data$iso_GCAMdata_results,
            file = level0path("GCAM_data_iso.RDS"))
  }


  #################################################
  ## LVL 1 scripts
  #################################################
  print("-- Start of level 1 scripts")

  print("-- Harmonizing energy intensities to match IEA final energy balances")
  ## function that harmonizes the data to the IEA balances to avoid mismatches in the historical time steps
  ## Final units:
  ## energy intensity (intensity_gcam): MJ/km
  intensity_gcam <- lvl1_IEAharmonization(tech_data = iso_data$iso_GCAMdata_results)
  if(saveRDS)
    saveRDS(intensity_gcam, file = level1path("harmonized_intensities.RDS"))

  print("-- Merge non-fuel prices with REMIND fuel prices")
  ## Final units:
  ## prices (REMIND_prices): in 1990USD/pkt (1990USD/tkm)
  REMIND_prices <- merge_prices(
    gdx = file.path(input_folder, "REMIND/fulldata.gdx"),
    REMINDmapping = REMIND2ISO_MAPPING,
    REMINDyears = years,
    intensity_data = intensity_gcam,
    nonfuel_costs = iso_data$iso_UCD_results$nec_iso[type == "normal"][, type := NULL],
    module = "edge_esm")

  if(saveRDS)
    saveRDS(REMIND_prices, file = level1path("full_prices.RDS"))


  print("-- EDGE calibration")
  ## two options of calibration: one is on partially on inconvenience costs and partially on preferences, the other is exclusively on preferences
  if (inconvenience) {
    calibration_output <- lvl1_calibrateEDGEinconv(
      prices = REMIND_prices,
      GCAM_data = iso_data$iso_GCAMdata_results,
      logit_exp_data = VOT_lambdas$logit_output,
      vot_data = iso_data$iso_VOT_results,
      price_nonmot = iso_data$iso_pricenonmot_results)
  } else {
    calibration_output <- lvl1_calibrateEDGE(
      prices = REMIND_prices,
      GCAM_data = iso_data$iso_GCAMdata_results,
      logit_exp_data = VOT_lambdas$logit_output,
      vot_data = iso_data$iso_VOT_results,
      price_nonmot = iso_data$iso_pricenonmot_results)
  }

  if(saveRDS)
    saveRDS(calibration_output, file = level1path("calibration_output.RDS"))

  print("-- cluster regions for share weight trends")
  clusters_overview <- lvl1_SWclustering(
    input_folder = input_folder,
    REMIND_scenario = REMIND_scenario,
    REMIND2ISO_MAPPING)

  density=clusters_overview[[1]]
  clusters=clusters_overview[[2]]
  
  if(saveRDS){
    saveRDS(clusters, file = level1path("clusters.RDS"))
    saveRDS(density, file = level1path("density.RDS"))
  }

  ## two options of projected preferences: one is on partially on inconvenience costs and partially on preferences, the other is exclusively on preferences
  if (inconvenience) {
    print("-- generating trends for inconvenience costs")
    prefs <- lvl1_preftrend(SWS = calibration_output$list_SW,
                            clusters = clusters,
                            incocost = incocost,
                            calibdem = iso_data$iso_GCAMdata_results[["tech_output"]],
                            years = years,
                            REMIND2ISO_MAPPING = REMIND2ISO_MAPPING,
                            REMIND_scenario = REMIND_scenario,
                            EDGE_scenario = EDGE_scenario,
                            smartlifestyle = smartlifestyle,
                            techswitch = techswitch)
    
    if(saveRDS)
      saveRDS(prefs, file = level1path("prefs.RDS"))

  } else {
    print("-- generating trends for share weights")
    SW <- lvl1_SWtrend(calibration_output,
                       clusters,
                       years,
                       REMIND_scenario = REMIND_scenario,
                       EDGE_scenario = EDGE_scenario)

    if(saveRDS)
      saveRDS(SW, file = level1path("SW.RDS"))
  }

  #################################################
  ## LVL 2 scripts
  #################################################
  print("-- Start of level 2 scripts")
  ## LOGIT calculation
  print("-- LOGIT calculation")
  ## two options of logit calculation: one is on partially on inconvenience costs and partially on preferences, the other is exclusively on preferences
  if (inconvenience) {
    ## filter out prices and intensities that are related to not used vehicles-technologies in a certain region
    REMIND_prices = merge(REMIND_prices, unique(prefs$FV_final_pref[, c("iso", "vehicle_type")]), by = c("iso", "vehicle_type"), all.y = TRUE)
    intensity_gcam = merge(intensity_gcam, unique(prefs$FV_final_pref[!(vehicle_type %in% c("Cycle_tmp_vehicletype", "Walk_tmp_vehicletype")) , c("iso", "vehicle_type")]), by = c("iso", "vehicle_type"), all.y = TRUE)
    logit_data <- calculate_logit_inconv_endog(
      prices = REMIND_prices,
      vot_data = iso_data$iso_VOT_results,
      pref_data = prefs,
      logit_params = VOT_lambdas$logit_output,
      intensity_data = intensity_gcam,
      price_nonmot = iso_data$iso_pricenonmot_results,
      techswitch = techswitch)

    if(saveRDS){
      saveRDS(logit_data[["share_list"]], file = level1path("share_newvehicles.RDS"))
      saveRDS(logit_data[["pref_data"]], file = level1path("pref_data.RDS"))
    }

  } else{
    logit_data <- calculate_logit(
      REMIND_prices,
      vot_data = iso_data$iso_VOT_results,
      sw_data = SW,
      logit_params = VOT_lambdas$logit_output,
      intensity_data = intensity_gcam,
      price_nonmot = iso_data$iso_pricenonmot_results)
  }

  if(saveRDS)
    saveRDS(logit_data, file = level2path("logit_data.RDS"))

  shares <- logit_data[["share_list"]] ## shares of alternatives for each level of the logit function
  mj_km_data <- logit_data[["mj_km_data"]] ## energy intensity at a technology level
  prices <- logit_data[["prices_list"]] ## prices at each level of the logit function, 1990USD/pkm

  ## regression demand calculation
  print("-- performing demand regression")
  dem_regr = lvl2_demandReg(tech_output = iso_data$iso_GCAMdata_results[["tech_output"]], 
                          price_baseline = prices$S3S, 
                          REMIND_scenario = REMIND_scenario, 
                          smartlifestyle = smartlifestyle)

  if(saveRDS)
    saveRDS(dem_regr, file = level2path("demand_regression.RDS"))


  ## calculate vintages (new shares, prices, intensity)
  vintages = calcVint(shares = shares,
                      totdem_regr = dem_regr,
                      prices = prices,
                      mj_km_data = mj_km_data,
                      years = years)


  shares$FV_shares = vintages[["shares"]]$FV_shares
  prices = vintages[["prices"]]
  mj_km_data = vintages[["mj_km_data"]]


 if(saveRDS)
    saveRDS(vintages, file = level2path("vintages.RDS"))
  
  print("-- aggregating shares, intensity and demand along REMIND tech dimensions")
  shares_intensity_demand <- shares_intensity_and_demand(
    logit_shares=shares,
    MJ_km_base=mj_km_data,
    EDGE2CESmap=EDGE2CESmap,
    REMINDyears=years,
    demand_input = dem_regr)
  
  demByTech <- shares_intensity_demand[["demand"]] ##in [-]
  intensity_remind <- shares_intensity_demand[["demandI"]] ##in million pkm/EJ


  print("-- Calculating budget coefficients")
  budget <- calculate_capCosts(
    base_price=prices$base,
    Fdemand_ES = shares_intensity_demand$demandF_plot_EJ,
    EDGE2CESmap = EDGE2CESmap,
    EDGE2teESmap = EDGE2teESmap,
    REMINDyears = years,
    scenario = scenario)

  ## full REMIND time range for inputs
  REMINDtall <- c(seq(1900,1985,5),
                  seq(1990, 2060, by = 5),
                  seq(2070, 2110, by = 10),
                  2130, 2150)

  ## prepare the entries to be saved in the gdx files: intensity, shares, non_fuel_price. Final entries: intensity in [trillionkm/Twa], capcost in [trillion2005USD/trillionpkm], shares in [-]
  print("-- final preparation of input files")
  finalInputs <- prepare4REMIND(
    demByTech = demByTech,
    intensity = intensity_remind,
    capCost = budget,
    EDGE2teESmap = EDGE2teESmap,
    REMINDtall = REMINDtall)


  ## calculate absolute values of demand. Final entry: demand in [trillionpkm]
  demand_traj <- lvl2_REMINDdemand(regrdemand = dem_regr,
                                   EDGE2teESmap = EDGE2teESmap,
                                   REMINDtall = REMINDtall,
                                   REMIND_scenario = REMIND_scenario)

  print("-- preparing complex module-friendly output files")
  ## final value: in billionspkm or billions tkm and EJ; shares are in [-]
  complexValues <- lvl2_reportingEntries(ESdem = shares_intensity_demand$demandF_plot_pkm,
                                         FEdem = shares_intensity_demand$demandF_plot_EJ)

  print("-- generating CSV files to be transferred to mmremind")
  if (inconvenience) {
    ## only the combinations (iso, vehicle) present in the mix have to be included in costs
    NEC_data = merge(iso_data$iso_UCD_results$nec_iso,
                     unique(calibration_output$list_SW$VS1_final_SW[,c("iso", "vehicle_type")]),
                     by =c("iso", "vehicle_type"))
    capcost4W = merge(iso_data$iso_UCD_results$capcost4W,
                      unique(calibration_output$list_SW$VS1_final_SW[,c("iso", "vehicle_type")]),
                      by =c("iso", "vehicle_type"))
    lvl2_createCSV_inconv(
      logit_params = VOT_lambdas$logit_output,
      pref_data = logit_data$pref_data,
      vot_data = iso_data$iso_VOT_results,
      int_dat = intensity_gcam,
      NEC_data = NEC_data,
      capcost4W = capcost4W,
      demByTech = finalInputs$demByTech,
      intensity = finalInputs$intensity,
      capCost = finalInputs$capCost,
      demand_traj = demand_traj,
      price_nonmot = iso_data$iso_pricenonmot_results,
      complexValues = complexValues,
      loadFactor = iso_data$iso_UCD_results$load_iso,
      REMIND_scenario = REMIND_scenario,
      EDGE_scenario = EDGE_scenario,
      level2path = level2path)

  } else {

    lvl2_createCSV(
      logit_params = VOT_lambdas$logit_output,
      sw_data = SW,
      vot_data = iso_data$iso_VOT_results,
      int_dat = intensity_gcam,
      NEC_data = iso_data$iso_UCD_results$nec_iso,
      demByTech = finalInputs$demByTech,
      intensity = finalInputs$intensity,
      capCost = finalInputs$capCost,
      demand_traj = demand_traj,
      price_nonmot = iso_data$iso_pricenonmot_results,
      complexValues = complexValues,
      REMIND_scenario = REMIND_scenario,
      EDGE_scenario = EDGE_scenario,
      level2path = level2path)
  }



}
