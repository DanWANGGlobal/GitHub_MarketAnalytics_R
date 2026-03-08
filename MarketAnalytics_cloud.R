#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics Script
# Modified for GitHub Actions + Nutstore WebDAV

# =============================================================================
# Environment Setup
# =============================================================================

# Get environment variables for cloud execution
WORK_DIR <- Sys.getenv("WORK_DIR", getwd())
INPUT_DIR <- file.path(WORK_DIR, "input")
OUTPUT_DIR <- file.path(WORK_DIR, "output")
DATA_ANALYSIS_DIR <- file.path(OUTPUT_DIR, "dataAnalysis")
CHARTING_DIR <- file.path(OUTPUT_DIR, "charting", "0html_ChartsPac")

# Create directories if not exist
for (dir in c(OUTPUT_DIR, DATA_ANALYSIS_DIR, CHARTING_DIR)) {
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  }
}

# Set working directory
setwd(WORK_DIR)

# =============================================================================
# Package Management (using renv in cloud)
# =============================================================================

# Load required packages
packages <- c(
  "Quandl", "pdfetch", "quantmod", "PerformanceAnalytics", 
  "PortfolioAnalytics", "lubridate", "openxlsx", "tidyverse",
  "tsibble", "slider", "kableExtra", "scales", "gt", "tidyquant",
  "tbl2xts", "xts", "ROI", "writexl", "ggpubr", "plotly",
  "TTR", "reticulate", "patchwork", "cowplot", "gridExtra",
  "ggExtra", "ggthemes", "ggrepel", "corrplot", "pdftools",
  "htmltools", "webshot2", "Cairo", "arrow", "fs", "here",
  "qpdf", "httr", "jsonlite"
)

# Install missing packages
install_if_missing <- function(pkg) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    message(paste("Installing package:", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# Load all packages
for (pkg in packages) {
  tryCatch({
    install_if_missing(pkg)
  }, error = function(e) {
    warning(paste("Failed to load package:", pkg, "-", conditionMessage(e)))
  })
}

message("All packages loaded successfully!")

# =============================================================================
# Parameters Configuration
# =============================================================================

dataHistory <- 10
eDate <- Sys.Date()
sDate <- eDate - years(dataHistory)

portfolioVol <- "ATR"  # "Vol" or "ATR"
maMode <- "EMA"        # "EMA" or "SMA"
maFun <- switch(maMode, "EMA" = TTR::EMA, "SMA" = TTR::SMA)
maParameters <- c(5, 21, 89, 144)

extremeCut <- c(0.01, 1 - 0.01)
warningCut <- c(0.05, 1 - 0.05)

VolCalWindow <- 20
ATRCalWindow <- 6
VaRCalWindow <- 750
RollWindow <- 180
CorWindow <- 60

ChgPeriod <- c(5, 20, 60, 120, 180, 250)
LeadMA <- "MAfast"
LagMA <- "MAslow"

dataCheck <- max(VolCalWindow, ATRCalWindow, VaRCalWindow, 
                 RollWindow, CorWindow, maParameters, ChgPeriod, 250)

head <- "TraderX-Flow-Cloud"
source_annotation <- list(
  x = 0, y = 0.01,
  text = "Cloud Analytics | GitHub Actions",
  showarrow = FALSE,
  xref = 'paper', yref = 'paper',
  xanchor = 'left', yanchor = 'auto',
  xshift = 0, yshift = 0,
  font = list(size = 10, color = "black")
)

# =============================================================================
# Logging Utility
# =============================================================================

log_message <- function(msg, level = "INFO") {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  log_entry <- paste0("[", timestamp, "] [", level, "] ", msg)
  message(log_entry)
  
  # Also write to log file
  log_file <- file.path(OUTPUT_DIR, "analysis.log")
  cat(log_entry, "\n", file = log_file, append = TRUE)
}

# =============================================================================
# Data Download Function
# =============================================================================

yahooDownload <- function(tickers, sDate, eDate) {
  log_message(paste("Starting data download for", nrow(tickers), "tickers"))
  
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:length(tickers$name)) {
    tryCatch({
      ticker <- tickers[i, ] %>%
        select(ticker) %>%
        select_if(~ any(!is.na(.)))
      
      log_message(paste("Downloading:", tickers$name[i], "(", ticker$ticker, ")"))
      
      yahooData[[i]] <- na.omit(
        getSymbols(ticker$ticker, from = sDate, to = eDate, 
                   src = "yahoo", auto.assign = FALSE)
      )
      
      yahooData[[i]] <- xts_tbl(yahooData[[i]])
      colnames(yahooData[[i]]) <- c("Date", "Open", "High", "Low", "Close", "Volume", "Last")
      
      log_message(paste("Successfully downloaded:", tickers$name[i]))
    },
    error = function(e) {
      log_message(paste("ERROR: Failed to download", tickers$name[i], 
                       "-", conditionMessage(e)), "ERROR")
      yahooData[[i]] <- NA
    })
  }
  
  # Save to output directory
  data_file <- file.path(OUTPUT_DIR, "data.xlsx")
  write.xlsx(yahooData, file = data_file, sheetName = tickers$name, overwrite = TRUE)
  
  eTime <- Sys.time()
  log_message(paste("Data download completed in", round(eTime - sTime, 2), "seconds"))
  
  invisible(yahooData)
}

# =============================================================================
# Data Analysis Function
# =============================================================================

DataAnalysis <- function(tickers) {
  log_message("Starting data analysis...")
  
  for (i in 1:length(tickers$name)) {
    tryCatch({
      log_message(paste("Analyzing:", tickers$name[i]))
      
      # Check if data file exists
      data_file <- file.path(OUTPUT_DIR, "data.xlsx")
      sheet_exists <- tickers$name[i] %in% getSheetNames(data_file)
      
      if (!sheet_exists) {
        log_message(paste("Skipping:", tickers$name[i], "- data not found"), "WARN")
        next
      }
      
      # Read data
      data <- tibble(read.xlsx(data_file, sheet = tickers$name[i]))
      
      if (length(data) == 0 || nrow(data) == 0) {
        log_message(paste("Skipping:", tickers$name[i], "- empty data"), "WARN")
        next
      }
      
      # Process data
      data <- data %>%
        select(Date, Last, High, Low) %>%
        mutate(Date = as.Date(Date, origin = "1899-12-30")) %>%
        drop_na()
      
      # Check data length
      if (nrow(data) <= dataCheck) {
        log_message(paste("Skipping:", tickers$name[i], "- insufficient data length"), "WARN")
        next
      }
      
      # Calculate indicators
      data <- calculateIndicators(data)
      
      # Rename columns
      data <- renameColumns(data)
      
      # Save analysis
      output_file <- file.path(DATA_ANALYSIS_DIR, 
                               paste0(tickers$name[i], "_DataAnalysis.xlsx"))
      write.xlsx(data, file = output_file, overwrite = TRUE)
      
      log_message(paste("Analysis saved:", tickers$name[i]))
      
    }, error = function(e) {
      log_message(paste("ERROR analyzing", tickers$name[i], ":", conditionMessage(e)), "ERROR")
    })
  }
  
  log_message("Data analysis completed!")
}

# Helper function to calculate indicators
calculateIndicators <- function(data) {
  data %>%
    mutate(
      LastHistRank = percent_rank(Last),
      LastRollRank = runPercentRank(Last, n = RollWindow, cumulative = FALSE),
      Range = High - Low,
      RangePerc = Range / lag(Last),
      Return = Last / lag(Last) - 1
    ) %>%
    mutate(
      HistMax = cummax(High),
      HistMin = cummin(Low),
      ToHistMax = (HistMax - Last) / Last,
      ToHistMin = (HistMin - Last) / Last,
      HistDrawDown = (Last - HistMax) / HistMax,
      HistDrawDownHistRank = percent_rank(HistDrawDown),
      HistDrawDownRollRank = runPercentRank(HistDrawDown, n = RollWindow, cumulative = FALSE),
      HistDrawUp = (Last - HistMin) / HistMin,
      HistDrawUpHistRank = percent_rank(HistDrawUp),
      HistDrawUpRollRank = runPercentRank(HistDrawUp, n = RollWindow, cumulative = FALSE)
    ) %>%
    # ATR calculations
    tq_mutate(Range, rollapply, width = ATRCalWindow, FUN = mean, col_rename = "ATR") %>%
    tq_mutate(RangePerc, rollapply, width = ATRCalWindow, FUN = mean, col_rename = "ATRPerc") %>%
    # Volatility
    tq_mutate(Return, rollapply, width = VolCalWindow, FUN = sd, col_rename = "DVol") %>%
    # VaR
    tq_mutate(Return, rollapply, width = VaRCalWindow, 
              FUN = function(x) quantile(x, extremeCut[1], na.rm = TRUE),
              col_rename = "LongVaRPerc") %>%
    tq_mutate(Return, rollapply, width = VaRCalWindow,
              FUN = function(x) quantile(x, extremeCut[2], na.rm = TRUE),
              col_rename = "ShortVaRPerc") %>%
    # Rolling Max/Min
    tq_mutate(High, rollapply, width = RollWindow, FUN = max, col_rename = "RollMax") %>%
    tq_mutate(Low, rollapply, width = RollWindow, FUN = min, col_rename = "RollMin") %>%
    mutate(
      RollDrawDown = Last / RollMax - 1,
      RollDrawUp = Last / RollMin - 1,
      RollDrawDownHistRank = percent_rank(RollDrawDown),
      RollDrawDownRollRank = runPercentRank(RollDrawDown, n = RollWindow, cumulative = FALSE),
      RollDrawUpHistRank = percent_rank(RollDrawUp),
      RollDrawUpRollRank = runPercentRank(RollDrawUp, n = RollWindow, cumulative = FALSE)
    ) %>%
    # Rankings
    mutate(
      DVolHistRank = percent_rank(DVol),
      DVolRollRank = runPercentRank(DVol, n = RollWindow, cumulative = FALSE),
      RangePercHistRank = percent_rank(RangePerc),
      RangePercRollRank = runPercentRank(RangePerc, n = RollWindow, cumulative = FALSE),
      ATRPercHistRank = percent_rank(ATRPerc),
      ATRPercRollRank = runPercentRank(ATRPerc, n = RollWindow, cumulative = FALSE)
    ) %>%
    # Moving Averages
    mutate(
      MAfast = maFun(Last, n = maParameters[1]),
      MAslow = maFun(Last, n = maParameters[2]),
      MAkey = maFun(Last, n = maParameters[3]),
      MAlongterm = maFun(Last, n = maParameters[4]),
      DevFast = Last / MAfast - 1,
      DevSlow = Last / MAslow - 1,
      DevKey = Last / MAkey - 1,
      DevLongterm = Last / MAlongterm - 1,
      DevMA_FastSlow = MAfast / MAslow - 1,
      DevKeyHistRank = percent_rank(DevKey),
      DevKeyRollRank = runPercentRank(DevKey, n = RollWindow, cumulative = FALSE)
    ) %>%
    # Changes
    tq_mutate(Last, ROC, n = ChgPeriod[1], type = "discrete", col_rename = "ChgA") %>%
    tq_mutate(Last, ROC, n = ChgPeriod[2], type = "discrete", col_rename = "ChgB") %>%
    tq_mutate(Last, ROC, n = ChgPeriod[3], type = "discrete", col_rename = "ChgC") %>%
    tq_mutate(Last, ROC, n = ChgPeriod[4], type = "discrete", col_rename = "ChgD") %>%
    tq_mutate(Last, ROC, n = ChgPeriod[5], type = "discrete", col_rename = "ChgE") %>%
    tq_mutate(Last, ROC, n = ChgPeriod[6], type = "discrete", col_rename = "ChgF") %>%
    mutate(
      SigmaA = ChgA / (DVol * sqrt(ChgPeriod[1])),
      SigmaB = ChgB / (DVol * sqrt(ChgPeriod[2])),
      SigmaC = ChgC / (DVol * sqrt(ChgPeriod[3])),
      SigmaD = ChgD / (DVol * sqrt(ChgPeriod[4])),
      SigmaE = ChgE / (DVol * sqrt(ChgPeriod[5])),
      SigmaF = ChgF / (DVol * sqrt(ChgPeriod[6]))
    )
}

# Helper function to rename columns
renameColumns <- function(data) {
  new_names <- c(
    paste0(maMode, maParameters[1]),
    paste0(maMode, maParameters[2]),
    paste0(maMode, maParameters[3]),
    paste0(maMode, maParameters[4]),
    paste0(maMode, "Dev", maParameters[1]),
    paste0(maMode, "Dev", maParameters[2]),
    paste0(maMode, "Dev", maParameters[3]),
    paste0(maMode, "Dev", maParameters[4]),
    paste0(maMode, "_MADev_", maParameters[1], "_", maParameters[2]),
    paste0(maMode, "Dev", maParameters[3], "HistRank"),
    paste0(maMode, "Dev", maParameters[3], "RollRank"),
    paste0("Chg", ChgPeriod[1], "DPerc"),
    paste0("Chg", ChgPeriod[2], "DPerc"),
    paste0("Chg", ChgPeriod[3], "DPerc"),
    paste0("Chg", ChgPeriod[4], "DPerc"),
    paste0("Chg", ChgPeriod[5], "DPerc"),
    paste0("Chg", ChgPeriod[6], "DPerc"),
    paste0("Sigma", ChgPeriod[1], "D"),
    paste0("Sigma", ChgPeriod[2], "D"),
    paste0("Sigma", ChgPeriod[3], "D"),
    paste0("Sigma", ChgPeriod[4], "D"),
    paste0("Sigma", ChgPeriod[5], "D"),
    paste0("Sigma", ChgPeriod[6], "D")
  )
  
  col_indices <- c(21:24, 25:31, 50:61)
  colnames(data)[col_indices] <- new_names
  
  return(data)
}

# =============================================================================
# Data Report Function
# =============================================================================

DataReport <- function(tickers) {
  log_message("Generating summary report...")
  
  # Get column names from first file
  first_file <- file.path(DATA_ANALYSIS_DIR, paste0(tickers$name[1], "_DataAnalysis.xlsx"))
  if (!file.exists(first_file)) {
    log_message("No analysis files found!", "ERROR")
    return(NULL)
  }
  
  getColums <- colnames(read.xlsx(first_file))
  Fields <- getColums[-1]
  lengthFields <- length(Fields)
  AnalysisLatest <- as.data.frame(matrix(nrow = 0, ncol = lengthFields + 1))
  colnames(AnalysisLatest) <- c("Name", Fields)
  
  # Fetch latest data for all instruments
  for (i in 1:length(tickers$name)) {
    log_message(paste("Processing report for:", tickers$name[i]))
    
    analysis_file <- file.path(DATA_ANALYSIS_DIR, 
                               paste0(tickers$name[i], "_DataAnalysis.xlsx"))
    
    if (!file.exists(analysis_file)) {
      log_message(paste("File not found, skipping:", tickers$name[i]), "WARN")
      next
    }
    
    tryCatch({
      temp <- read.xlsx(analysis_file)
      temp <- temp[nrow(temp), Fields]
      AnalysisLatest[i, ] <- c(tickers$name[i], temp)
      log_message(paste("Added to report:", tickers$name[i]))
    }, error = function(e) {
      log_message(paste("Error processing:", tickers$name[i]), "ERROR")
    })
  }
  
  # Convert to numeric
  for (i in 2:ncol(AnalysisLatest)) {
    AnalysisLatest[, i] <- as.double(AnalysisLatest[, i])
  }
  
  AnalysisLatest <- drop_na(tibble(AnalysisLatest))
  
  # Save plain version
  plain_file <- file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.xlsx"))
  write.xlsx(AnalysisLatest, file = plain_file, overwrite = TRUE)
  
  csv_file <- file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.csv"))
  write.csv(AnalysisLatest, csv_file, row.names = FALSE)
  
  # Save formatted version using template
  template_file <- file.path(INPUT_DIR, "template_AnalysisReport.xlsx")
  if (file.exists(template_file)) {
    template <- loadWorkbook(template_file)
    writeData(template, sheet = 1, x = AnalysisLatest, 
              startRow = 4, startCol = 1, colNames = FALSE, withFilter = FALSE)
    formal_file <- file.path(OUTPUT_DIR, "AnalysisReport_formal.xlsx")
    saveWorkbook(template, file = formal_file, overwrite = TRUE)
    log_message("Formatted report saved")
  } else {
    log_message("Template not found, using plain format", "WARN")
  }
  
  log_message("Report generation completed!")
}

# =============================================================================
# Data Visualization Function (Simplified for Cloud)
# =============================================================================

DataVisualization <- function(tickers) {
  log_message("Starting data visualization...")
  
  for (i in 1:length(tickers$name)) {
    inputTicker <- tickers$name[i]
    
    log_message(paste("Creating charts for:", inputTicker))
    
    analysis_file <- file.path(DATA_ANALYSIS_DIR, 
                               paste0(inputTicker, "_DataAnalysis.xlsx"))
    
    if (!file.exists(analysis_file)) {
      log_message(paste("Analysis file not found, skipping:", inputTicker), "WARN")
      next
    }
    
    tryCatch({
      Data <- tibble(read.xlsx(analysis_file))
      Data$Date <- as.Date(Data$Date, origin = "1899-12-30")
      
      # Create simplified price chart
      Prices <- Data %>%
        plot_ly(type = 'scatter', mode = 'lines') %>%
        add_trace(x = Data[[1]], y = Data[[2]], 
                  name = paste(colnames(Data)[2], ":", round(Data[[2]][nrow(Data)], 2), sep = ""),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = Data[[1]], y = Data[[21]], 
                  name = paste(colnames(Data)[21], ":", round(Data[[21]][nrow(Data)], 2), sep = ""),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = Data[[1]], y = Data[[22]], 
                  name = paste(colnames(Data)[22], ":", round(Data[[22]][nrow(Data)], 2), sep = ""),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Prices"))
      
      # Save HTML (cloud-compatible)
      html_file <- file.path(CHARTING_DIR, paste0(Sys.Date(), "_", inputTicker, ".html"))
      htmlwidgets::saveWidget(Prices, file = html_file, selfcontained = TRUE)
      
      log_message(paste("Charts saved for:", inputTicker))
      
    }, error = function(e) {
      log_message(paste("Error creating charts for", inputTicker, ":", conditionMessage(e)), "ERROR")
    })
  }
  
  log_message("Visualization completed!")
}

# =============================================================================
# Main Execution
# =============================================================================

main <- function() {
  log_message("============================================")
  log_message("Cloud Market Analytics Pipeline Started")
  log_message(paste("Working Directory:", WORK_DIR))
  log_message(paste("Analysis Date:", eDate))
  log_message("============================================")
  
  # Read input tickers
  tickers_file <- file.path(INPUT_DIR, "tickers_macro.xlsx")
  if (!file.exists(tickers_file)) {
    log_message(paste("Tickers file not found:", tickers_file), "ERROR")
    stop("Input file not found!")
  }
  
  instruments <- read.xlsx(tickers_file)
  log_message(paste("Loaded", nrow(instruments), "instruments"))
  
  # Execute pipeline
  log_message("Step 1/4: Downloading data from Yahoo Finance...")
  yahooDownload(instruments, sDate, eDate)
  
  log_message("Step 2/4: Analyzing data...")
  DataAnalysis(instruments)
  
  log_message("Step 3/4: Generating report...")
  DataReport(instruments)
  
  log_message("Step 4/4: Creating visualizations...")
  DataVisualization(instruments)
  
  log_message("============================================")
  log_message("Analysis Pipeline Completed Successfully!")
  log_message("============================================")
  
  # List output files
  output_files <- list.files(OUTPUT_DIR, recursive = TRUE, full.names = TRUE)
  log_message(paste("Generated", length(output_files), "output files"))
}

# Run main function
main()
