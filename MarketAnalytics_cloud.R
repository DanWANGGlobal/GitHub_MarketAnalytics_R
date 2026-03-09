#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics - 完整修复版
# 修复slider错误，优化包安装，确保与本地版本输出一致

# =============================================================================
# Environment Setup
# =============================================================================

WORK_DIR <- Sys.getenv("WORK_DIR", getwd())
INPUT_DIR <- file.path(WORK_DIR, "input")
OUTPUT_DIR <- file.path(WORK_DIR, "output")
DATA_ANALYSIS_DIR <- file.path(OUTPUT_DIR, "dataAnalysis")
CHARTING_DIR <- file.path(OUTPUT_DIR, "charting", "0html_ChartsPac")

for (dir in c(OUTPUT_DIR, DATA_ANALYSIS_DIR, CHARTING_DIR)) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
}
setwd(WORK_DIR)

# =============================================================================
# Package Management - 优化版（避免重复安装）
# =============================================================================

message("Loading packages...")

# 基础包列表
packages <- c("quantmod", "xts", "openxlsx", "dplyr", "lubridate", "zoo", 
              "TTR", "plotly", "htmltools", "htmlwidgets", "tidyquant", 
              "PerformanceAnalytics", "slider", "scales")

# 优化的包加载逻辑 - 只安装缺失的包
missing_packages <- c()
for (pkg in packages) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    missing_packages <- c(missing_packages, pkg)
  }
}

# 批量安装缺失的包（只执行一次）
if (length(missing_packages) > 0) {
  message(paste("Installing missing packages:", paste(missing_packages, collapse = ", ")))
  install.packages(missing_packages, repos = "https://cloud.r-project.org/", quiet = TRUE, Ncpus = 2)
  # 加载新安装的包
  for (pkg in missing_packages) {
    library(pkg, character.only = TRUE)
  }
}

message("Packages loaded!")

# =============================================================================
# Parameters - 完全匹配原始
# =============================================================================

dataHistory <- 10
eDate <- Sys.Date()
sDate <- eDate - years(dataHistory)

maMode <- "EMA"
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

dataCheck <- max(VolCalWindow, ATRCalWindow, VaRCalWindow, RollWindow, CorWindow, 
                 maParameters, ChgPeriod, 250)

head <- "TraderX-Flow"
source_annotation <- list(
  x = 0, y = 0.01,
  text = "微信公众号【TraderX-Flow】",
  showarrow = FALSE,
  xref = 'paper', yref = 'paper',
  xanchor = 'left', yanchor = 'auto',
  font = list(size = 10, color = "black")
)

# =============================================================================
# Helper Functions
# =============================================================================

xts_to_tbl <- function(xts_data) {
  df <- as.data.frame(xts_data)
  df$Date <- index(xts_data)
  rownames(df) <- NULL
  return(tibble::as_tibble(df))
}

# =============================================================================
# Data Download - 带重试
# =============================================================================

yahooDownload <- function(tickers, sDate, eDate) {
  message("Downloading data from Yahoo Finance...")
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:nrow(tickers)) {
    symbol <- tickers$ticker[i]
    name <- tickers$name[i]
    
    message(paste("[", i, "/", nrow(tickers), "]", name, "(", symbol, ")"))
    
    success <- FALSE
    for (attempt in 1:3) {
      if (attempt > 1) {
        message(paste("  Retry attempt", attempt))
        Sys.sleep(2)
      }
      
      tryCatch({
        data <- getSymbols(symbol, from = sDate, to = eDate, 
                          src = "yahoo", auto.assign = FALSE)
        
        if (!is.null(data) && nrow(data) > 0) {
          df <- xts_to_tbl(data)
          colnames(df) <- c("Open", "High", "Low", "Close", "Volume", "Last", "Date")
          df <- df[, c("Date", "Open", "High", "Low", "Close", "Volume", "Last")]
          yahooData[[name]] <- df
          message(paste("  SUCCESS:", nrow(df), "rows"))
          success <- TRUE
          break
        }
      }, error = function(e) {
        message(paste("  Attempt", attempt, "failed:", conditionMessage(e)))
      })
    }
    
    if (!success) {
      message(paste("  FAILED:", name))
      yahooData[[name]] <- NA
    }
  }
  
  # 保存数据
  valid_data <- yahooData[!sapply(yahooData, is.null)]
  if (length(valid_data) > 0) {
    write.xlsx(valid_data, file.path(OUTPUT_DIR, "data.xlsx"), overwrite = TRUE)
  }
  
  eTime <- Sys.time()
  message(paste("Download completed in", round(eTime - sTime, 2), "seconds"))
  invisible(yahooData)
}

# =============================================================================
# Data Analysis - 修复slider错误版本
# =============================================================================

DataAnalysis <- function(tickers) {
  for (i in 1:nrow(tickers)) {
    name <- tickers$name[i]
    message(paste(name, ": started analysis..."))
    
    tryCatch({
      # 读取数据
      data_file <- file.path(OUTPUT_DIR, "data.xlsx")
      if (!file.exists(data_file)) {
        message("  ERROR: data.xlsx not found")
        next
      }
      
      all_sheets <- getSheetNames(data_file)
      if (!(name %in% all_sheets)) {
        message(paste("  ERROR: Sheet", name, "not found"))
        next
      }
      
      data <- read.xlsx(data_file, sheet = name)
      if (is.null(data) || nrow(data) == 0) {
        message("  ERROR: No data")
        next
      }
      
      # 基础数据处理 - 完全匹配原始
      data <- data %>%
        select(Date, Last, High, Low)
      data$Date <- as.Date(data$Date, origin = "1899-12-30")
      data <- na.omit(data)
      
      if (nrow(data) <= dataCheck) {
        message(paste("  SKIP: Insufficient data (", nrow(data), "rows)"))
        next
      }
      
      # 核心计算 - 修复slider错误：使用tail获取最后一个值的排名
      data <- data %>%
        mutate(
          LastHistRank = percent_rank(Last),
          # 修复：percent_rank返回向量，需要取最后一个值
          LastRollRank = slider::slide_dbl(Last, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        ) %>%
        mutate(
          Range = High - Low,
          RangePerc = Range / lag(Last),
          Return = Last / lag(Last) - 1
        ) %>%
        mutate(
          HistMax = cummax(High),
          HistMin = cummin(Low)
        ) %>%
        mutate(
          ToHistMax = (HistMax - Last) / Last,
          ToHistMin = (HistMin - Last) / Last,
          HistDrawDown = (Last - HistMax) / HistMax,
          HistDrawDownHistRank = percent_rank(HistDrawDown),
          # 修复slider错误
          HistDrawDownRollRank = slider::slide_dbl(HistDrawDown, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          HistDrawUp = (Last - HistMin) / HistMin,
          HistDrawUpHistRank = percent_rank(HistDrawUp),
          # 修复slider错误
          HistDrawUpRollRank = slider::slide_dbl(HistDrawUp, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      # ATR和波动率
      data <- data %>%
        mutate(
          ATR = zoo::rollapply(Range, ATRCalWindow, mean, fill = NA, align = "right"),
          ATRPerc = zoo::rollapply(RangePerc, ATRCalWindow, mean, fill = NA, align = "right"),
          DVol = zoo::rollapply(Return, VolCalWindow, sd, fill = NA, align = "right")
        )
      
      # VaR
      data$LongVaRPerc <- zoo::rollapply(data$Return, VaRCalWindow, 
                                         function(x) quantile(x, extremeCut[1], na.rm = TRUE), 
                                         fill = NA, align = "right")
      data$ShortVaRPerc <- zoo::rollapply(data$Return, VaRCalWindow, 
                                          function(x) quantile(x, extremeCut[2], na.rm = TRUE), 
                                          fill = NA, align = "right")
      
      # 排名计算 - 修复所有slider错误
      data <- data %>%
        mutate(
          RangePercHistRank = percent_rank(RangePerc),
          RangePercRollRank = slider::slide_dbl(RangePerc, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          ATRPercHistRank = percent_rank(ATRPerc),
          ATRPercRollRank = slider::slide_dbl(ATRPerc, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          DVolHistRank = percent_rank(DVol),
          DVolRollRank = slider::slide_dbl(DVol, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      # RollMax/Min
      data <- data %>%
        mutate(
          RollMax = zoo::rollapply(High, RollWindow, max, fill = NA, align = "right"),
          RollMin = zoo::rollapply(Low, RollWindow, min, fill = NA, align = "right")
        ) %>%
        mutate(
          RollDrawDown = Last / RollMax - 1,
          RollDrawUp = Last / RollMin - 1,
          RollDrawDownHistRank = percent_rank(RollDrawDown),
          RollDrawDownRollRank = slider::slide_dbl(RollDrawDown, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          RollDrawUpHistRank = percent_rank(RollDrawUp),
          RollDrawUpRollRank = slider::slide_dbl(RollDrawUp, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      # 移动平均 - 使用原始命名
      data <- data %>%
        mutate(
          EMA5 = maFun(Last, n = maParameters[1]),
          EMA21 = maFun(Last, n = maParameters[2]),
          EMA89 = maFun(Last, n = maParameters[3]),
          EMA144 = maFun(Last, n = maParameters[4])
        ) %>%
        mutate(
          EMADev5 = Last / EMA5 - 1,
          EMADev21 = Last / EMA21 - 1,
          EMADev89 = Last / EMA89 - 1,
          EMADev144 = Last / EMA144 - 1,
          EMA_MADev_5_21 = EMA5 / EMA21 - 1,
          EMADev89HistRank = percent_rank(EMADev89),
          EMADev89RollRank = slider::slide_dbl(EMADev89, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      # 收益率和Sigma - 完全匹配原始
      for (j in 1:length(ChgPeriod)) {
        period <- ChgPeriod[j]
        chg_col <- paste0("Chg", period, "DPerc")
        sigma_col <- paste0("Sigma", period, "D")
        
        data[[chg_col]] <- c(rep(NA, period), diff(data$Last, period) / lag(data$Last, period)[(period + 1):nrow(data)])
        data[[sigma_col]] <- data[[chg_col]] / (data$DVol * sqrt(period))
      }
      
      # 选择输出列 - 完全匹配原始
      output_cols <- c("Date", "Last", "High", "Low", "Return",
                       "Range", "RangePerc", "ATR", "ATRPerc", "DVol",
                       "LongVaRPerc", "ShortVaRPerc",
                       "RangePercHistRank", "RangePercRollRank",
                       "ATRPercHistRank", "ATRPercRollRank",
                       "DVolHistRank", "DVolRollRank",
                       "LastHistRank", "LastRollRank",
                       "EMA5", "EMA21", "EMA89", "EMA144",
                       "EMADev5", "EMADev21", "EMADev89", "EMADev144", "EMA_MADev_5_21",
                       "EMADev89HistRank", "EMADev89RollRank",
                       "HistMax", "HistMin", "ToHistMax", "ToHistMin",
                       "HistDrawDown", "HistDrawUp",
                       "HistDrawDownHistRank", "HistDrawDownRollRank", "HistDrawUpHistRank", "HistDrawUpRollRank",
                       "RollMax", "RollMin",
                       "RollDrawDown", "RollDrawUp",
                       "RollDrawDownHistRank", "RollDrawDownRollRank", "RollDrawUpHistRank", "RollDrawUpRollRank")
      
      # 添加Chg和Sigma列
      for (period in ChgPeriod) {
        output_cols <- c(output_cols, paste0("Chg", period, "DPerc"), paste0("Sigma", period, "D"))
      }
      
      # 确保所有列都存在
      for (col in output_cols) {
        if (!(col %in% names(data))) {
          data[[col]] <- NA
        }
      }
      
      data <- data[, output_cols]
      
      # 保存
      write.xlsx(data, file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx")), overwrite = TRUE)
      message(paste("  SAVED:", name, "_DataAnalysis.xlsx"))
      
    }, error = function(e) {
      message(paste("  ERROR analyzing", name, ":", conditionMessage(e)))
    })
  }
}

# =============================================================================
# Data Report - 完全还原原始版本
# =============================================================================

DataReport <- function(tickers) {
  message("Generating report...")
  
  # 获取列名模板 - 使用BTCUSD作为模板
  template_file <- file.path(DATA_ANALYSIS_DIR, "BTCUSD_DataAnalysis.xlsx")
  if (!file.exists(template_file)) {
    # 如果BTCUSD不存在，使用第一个可用的文件
    available_files <- list.files(DATA_ANALYSIS_DIR, pattern = "_DataAnalysis.xlsx$", full.names = TRUE)
    if (length(available_files) == 0) {
      message("ERROR: No DataAnalysis files found")
      return()
    }
    template_file <- available_files[1]
  }
  
  template_data <- read.xlsx(template_file)
  fields <- colnames(template_data)[-1]  # 排除Date列
  
  # 创建结果数据框
  results <- data.frame(matrix(nrow = 0, ncol = length(fields) + 1))
  colnames(results) <- c("Name", fields)
  
  # 获取每个品种的最新数据
  for (i in 1:nrow(tickers)) {
    name <- tickers$name[i]
    message(paste("Report - Fetching:", name))
    
    file_path <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file_path)) {
      message(paste("  SKIP: File not found"))
      next
    }
    
    tryCatch({
      data <- read.xlsx(file_path)
      if (nrow(data) == 0) {
        message(paste("  SKIP: Empty data"))
        next
      }
      
      # 获取最后一行（排除Date列）
      last_row <- data[nrow(data), -1]
      
      # 添加到结果
      new_row <- c(name, as.list(last_row))
      results[nrow(results) + 1, ] <- new_row
      message(paste("  ADDED:", name))
      
    }, error = function(e) {
      message(paste("  ERROR:", name, conditionMessage(e)))
    })
  }
  
  # 转换数值列
  for (i in 2:ncol(results)) {
    results[, i] <- as.numeric(as.character(results[, i]))
  }
  
  # 移除NA行
  results <- na.omit(results)
  
  # 保存plain版本
  write.xlsx(results, file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.xlsx")), overwrite = TRUE)
  write.csv(results, file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.csv")), row.names = FALSE)
  
  # 使用模板生成formal版本
  template_wb <- file.path(INPUT_DIR, "template_AnalysisReport.xlsx")
  if (file.exists(template_wb)) {
    wb <- loadWorkbook(template_wb)
    writeData(wb, sheet = 1, x = results, startRow = 4, startCol = 1, colNames = FALSE)
    saveWorkbook(wb, file.path(OUTPUT_DIR, "AnalysisReport_formal.xlsx"), overwrite = TRUE)
    message("Formal report saved: AnalysisReport_formal.xlsx")
  } else {
    message("WARNING: template_AnalysisReport.xlsx not found, using plain version")
    write.xlsx(results, file.path(OUTPUT_DIR, "AnalysisReport_formal.xlsx"), overwrite = TRUE)
  }
  
  message(paste("Report completed:", nrow(results), "instruments"))
}

# =============================================================================
# Data Visualization - 简化版（确保兼容性）
# =============================================================================

DataVisualization <- function(tickers) {
  message("Creating charts...")
  
  for (i in 1:nrow(tickers)) {
    name <- tickers$name[i]
    message(paste("Chart:", name))
    
    file_path <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file_path)) {
      message(paste("  SKIP: File not found"))
      next
    }
    
    tryCatch({
      Data <- read.xlsx(file_path)
      Data$Date <- as.Date(Data$Date, origin = "1899-12-30")
      Data <- Data %>% filter(!is.na(Last))
      
      if (nrow(Data) < 30) {
        message(paste("  SKIP: Insufficient data"))
        next
      }
      
      # 简化版图表 - 只创建价格图表（确保兼容性）
      p <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~Last, name = paste("Last:", round(tail(Data$Last, 1), 2)),
                  line = list(color = "black", width = 1)) %>%
        layout(title = list(text = paste(eDate, "|", name, "|Price@", head, sep = ""),
                            font = list(size = 15)),
               xaxis = list(title = ""),
               yaxis = list(title = "Price"),
               annotations = list(source_annotation))
      
      # 保存
      html_file <- file.path(CHARTING_DIR, paste0(eDate, "_", name, ".html"))
      htmlwidgets::saveWidget(p, html_file, selfcontained = TRUE)
      message(paste("  SAVED:", html_file))
      
    }, error = function(e) {
      message(paste("  ERROR:", name, conditionMessage(e)))
    })
  }
  
  message("Charts completed!")
}

# =============================================================================
# Main
# =============================================================================

main <- function() {
  message("============================================")
  message("Market Analytics Pipeline - Fixed Version")
  message(paste("Date:", eDate))
  message("============================================")
  
  # 读取品种列表
  tickers_file <- file.path(INPUT_DIR, "tickers_macro.xlsx")
  if (!file.exists(tickers_file)) {
    message("FATAL ERROR: tickers_macro.xlsx not found!")
    return()
  }
  
  instruments <- read.xlsx(tickers_file)
  message(paste("Loaded", nrow(instruments), "instruments"))
  
  # 下载数据
  message("\nStep 1/4: Downloading data...")
  yahooDownload(instruments, sDate, eDate)
  
  # 数据分析
  message("\nStep 2/4: Analyzing data...")
  DataAnalysis(instruments)
  
  # 生成报告
  message("\nStep 3/4: Generating report...")
  DataReport(instruments)
  
  # 创建图表
  message("\nStep 4/4: Creating charts...")
  DataVisualization(instruments)
  
  message("\n============================================")
  message("Pipeline Completed!")
  message("============================================")
}

# 运行
main()
