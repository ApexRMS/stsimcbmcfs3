---
layout: default
title: Home
description: "SyncroSim package for forest carbon modeling"
permalink: /
---

# **ST-Sim CBM-CFS3** SyncroSim Package
<img align="right" style="padding: 13px" width="180" src="assets/images/logo/stsimcbmcfs3-sticker.png">
[![GitHub release](https://img.shields.io/github/v/release/ApexRMS/stsimcbmcfs3.svg?style=for-the-badge&color=d68a06)](https://GitHub.com/ApexRMS/stsimcbmcfs3/releases/)    <a href="https://github.com/ApexRMS/stsimcbmcfs3"><img align="middle" style="padding: 1px" width="30" src="assets/images/logo/github-trans2.png">
<br>
## Landscape scale forest carbon simulations
### *ST-Sim CBM-CFS3* is an open-source <a href="https://syncrosim.com/download/" target="_blank">Syncrosim</a> add-on package to <a href="http://docs.stsim.net" target="_blank">ST-Sim</a> for integrating dynamics from the Carbon Budget Model for the Canadian Forest Sector (CBM-CFS3) into the ST-Sim landscape simulation model.

**ST-Sim CBM-CFS3** integrates inputs and outputs from the <a href="https://www.nrcan.gc.ca/climate-change/impacts-adaptations/climate-change-impacts-forests/carbon-accounting/carbon-budget-model/13107" target="_blank">Carbon Budget Model</a> for the Canadian Forest Sector (CBM-CFS3) into landscape scale simulations using the <a href="http://docs.stsim.net" target="_blank">ST-Sim</a> and <a href="https://apexrms.github.io/stsimsf/" target="_blank">stsimsf</a> <a href="https://syncrosim.com/" target="_blank">Syncrosim</a> packages. The package allows users to load outputs from the CBM-CFS3, calculate flow rates by carbon pool based on CBM-CFS3 parameters and user defined temperatures, run spin up simulations to create initial carbon maps based on forest type and recent disturbance, and generate spatially explicit forecasts of forest carbon under alternative scenarios.

**ST-Sim CBM-CFS3** is a package that plugs into the <a href="https://syncrosim.com/" target="_blank">Syncrosim</a> modeling framework. It can also be run from the R programming language using the <a href="https://syncrosim.com/r-package/" target="_blank">rsyncrosim</a> R package and from the Python programming language using the <a href="https://pysyncrosim.readthedocs.io/en/latest/" target="_blank">pysyncrosim</a> Python package.

## Requirements

This package requires the following software: <br>
SyncroSim <a href="https://syncrosim.com/download/" target="_blank">2.3.11 or later</a>. <br>
<a href="https://www.nrcan.gc.ca/climate-change/impacts-adaptations/climate-change-impacts-forests/carbon-accounting/carbon-budget-model/13107" target="_blank">Carbon Budget Model</a> for the Canadian Forest Sector. <br>
R <a href="https://www.r-project.org/" target="_blank">version 4.0.2</a> or higher. <br>
Syncrosim packages <a href="https://docs.stsim.net/" target="_blank">*stsim* and *stsimsf*</a>. <br>
Microsoft Access Database Engine <a href="https://www.microsoft.com/en-us/download/details.aspx?id=54920" target="_blank">2016 Redistributable</a>

## How to Install

For installation instructions, see the **Install ST-Sim CBM-CFS3** section on the [Getting Started](https://apexrms.github.io/stsimcbmcfs3/getting_started.html) page.

## Getting Started

For more information on **ST-Sim CBM-CFS3**, including a Quickstart Tutorial, see the [Getting Started](https://apexrms.github.io/stsimcbmcfs3/getting_started.html) page.

## Templates

- CBM-CFS3 Example: Library containing example inputs and outputs for the **ST-Sim CBM-CFS3** SyncroSim package.
- CBM-CFS3 CONUS: **ST-Sim CBM-CFS3** Library containing the 29 forest types required to run forest carbon simulations for CONUS.

## Links

Browse source code at <a href="https://github.com/ApexRMS/stsimcbmcfs3/" target="_blank">https://github.com/ApexRMS/stsimcbmcfs3/</a>
<br>
Report a bug at <a href="https://github.com/ApexRMS/stsimcbmcfs3/issues" target="_blank">https://github.com/ApexRMS/stsimcbmcfs3/issues</a>

## Developers

Leonardo Frid (Author, maintainer) <a href="https://orcid.org/0000-0002-5489-2337"><img align="middle" style="padding: 0.5px" width="17" src="assets/images/ORCID.png"></a>
<br>
Bronwyn Rayfield (Author) <a href="https://orcid.org/0000-0003-1768-1300"><img align="middle" style="padding: 0.5px" width="17" src="assets/images/ORCID.png"></a>
<br>
Benjamin Sleeter (Author) <a href="https://orcid.org/0000-0003-2371-9571"><img align="middle" style="padding: 0.5px" width="17" src="assets/images/ORCID.png"></a>
<br>
Schuyler Pearman-Gillman (Author) <a href="https://orcid.org/0000-0002-3911-1985"><img align="middle" style="padding: 0.5px" width="17" src="assets/images/ORCID.png"></a>
<br>
Colin Daniel (Author)
