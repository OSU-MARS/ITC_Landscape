library(caret)
library(dplyr)
library(FNN)
library(magrittr)
library(ranger)
library(stringr)
library(terra)
library(tidyr)
library(tidyterra)

jobStartTime = Sys.time()

# default to using half of CPU's threads per job
# ranger::predict() isn't DDR bandwidth limited but jobs tend to synchronize in prediction due to core competition. Constraining ranger
# yields somewhat higher average CPU utilization and DDR bandwidth.
classificationOptions = tibble(gridMetricsResamplingMethod = "cubic",
                               gridMetricsResolution = 1.8, # m
                               rangerThreads = 0.5 * future::availableCores(), # TBD if one third would be more effective for three jobs
                               generateVrt = FALSE)

chunkIndex = 1 # 9900X: ~1 minute/tile, max ~20 GB DDR @ < 20 GB/s per job
chunkSize = 187 # 561 tiles -> three jobs of ~3.3 hours for subclasses (12 PCA predictors), ~2.5 hours 9900X runtime (12 PCA predictors, classes)

dataPath = "D:/Elliott/GIS/DOGAMI/2021 OLC Coos County"
randomForestFit = readRDS(file.path(getwd(), sprintf("trees/segmentation/classificationRandomForest PCA12 iQ17hQ29csr 3800 %.1fm m9n25 cubic subclass.Rds", classificationOptions$gridMetricsResolution)))
dataDestinationPath = file.path(dataPath, "classification", sprintf("PCA12 iQ17hQ29csr 3800 %.1fm m9n25 cubic subclass", classificationOptions$gridMetricsResolution))

dsmSourcePath = file.path(dataPath, "DSM v3 beta")
dsmSlopeAspectSourcePath = file.path(dataPath, "DSM v3 beta", "slopeAspect")
dsmPointsSourcePath = file.path(dataPath, "DSM v3 beta", "nPoints")
dtmSourcePath = file.path(dataPath, "DTM")
orthoimageSourcePath = file.path(dataPath, "orthoimage v3")
tileNames = list.files(orthoimageSourcePath, "\\.tif$")

startIndex = chunkSize * (chunkIndex - 1) + 1
endIndex = min(chunkSize * chunkIndex, length(tileNames))
tileNames = tileNames[startIndex:endIndex]

# constrain memory consumption by loading only the grid metrics used by the fitted model
# For now, it's assumed only one grid metrics scale is used. Model variable names are suffixed with the scale but are not suffixed in the
# grid metrics virtual rasters, so the suffix is str_remove()d. Since the virtual rasters contain elevations rather than heights, the h
# prefix is swapped for z and and zGroundMean is always included to allow conversion to heights.
gridMetricsLayers = c(str_replace(str_remove(str_subset(randomForestFit$forest$independent.variable.names, "\\d\\d\\d$"), "_?\\d\\d\\d$"), "^h", "z"), "zGroundMean")
if (classificationOptions$gridMetricsResolution == 1.8)
{
  gridMetrics018 = rast(file.path(dataPath, "metrics", "1.8 m", "gridMetrics.vrt"), lyrs = gridMetricsLayers) %>%
    rename_with(~str_c(., if_else(str_ends(., "\\d"), "_018", "018")))
} else if (classificationOptions$gridMetricsResolution == 3.0) {
  gridMetrics030 = rast(file.path(dataPath, "metrics", "3.0 m", "gridMetrics.vrt"), lyrs = gridMetricsLayers) %>%
    rename_with(~str_c(., if_else(str_ends(., "\\d"), "_030", "030")))
} else if (classificationOptions$gridMetricsResolution == 4.6) {
  gridMetrics046 = rast(file.path(dataPath, "metrics", "4.6 m", "gridMetrics.vrt"), lyrs = gridMetricsLayers) %>%
    rename_with(~str_c(., if_else(str_ends(., "\\d"), "_046", "046")))
} else if (classificationOptions$gridMetricsResolution == 10.0) {
  gridMetrics100 = rast(file.path(dataPath, "metrics", "grid metrics 10 m non-normalized v2.tif", lyrs = gridMetricsLayers)) %>%
    rename_with(~str_c(., if_else(str_ends(., "\\d"), "_100", "100")))
}
dtmAspect100cosine = rast(file.path(dataPath, "bare earth cos(aspect) Gaussian 10 m EPSG6557.tif")) %>%
  rename(aspect100cosine = `bare earth cos(aspect) Gaussian 10 m EPSG6557`)
dtmAspect100sine = rast(file.path(dataPath, "bare earth sin(aspect) Gaussian 10 m EPSG6557.tif")) %>%
  rename(aspect100sine = `bare earth sin(aspect) Gaussian 10 m EPSG6557`)

imageCenters = vect("GIS/DOGAMI/2021 OLC Coos County/image positions.gpkg") # terra drops z coordinates but they're redundant with the elevation field
imageCentersForKnn = tibble(xy = geom(imageCenters), z = imageCenters$`elevation, ft`) %>% # flatten to coordinates for kNN
  mutate(x = xy[, "x"], y = xy[, "y"]) %>% select(-xy) %>% relocate(x, y, z)
imageSunPositions = tibble(azimuth = imageCenters$sunAzimuth, elevation = imageCenters$sunElevation) # flatten for in loop lookup
rm(imageCenters)

## classify orthoimages plus DSM
# 9900X: TBD 2000 x 2000 tiles/min
cat(paste0("Processing chunk ", chunkIndex, " (indices ", startIndex, ":", endIndex, sprintf(") with %.1f m grid metrics", classificationOptions$gridMetricsResolution), ": ", length(tileNames), " tiles..."))
for (tileIndex in 1:length(tileNames))
{
  tileName = tileNames[tileIndex]
  classificationRasterPath = file.path(dataDestinationPath, tileName)
  if (file.exists(classificationRasterPath))
  {
    next
  }
  
  # load tile data
  tileOrthoimage = rast(file.path(orthoimageSourcePath, tileName)) %>% # can't use lyrs argument here as not all tiles have near infrared bands
    select(-intensityFirstReturn, -intensitySecondReturn) # trim memory consumption: first and second return intensity not currently used
  if ("nearInfrared" %in% names(tileOrthoimage))
  {
    cat(paste0(tileIndex, ": ", str_remove(tileName, "\\.tif"), "...\n"))
  } else {
    cat(paste0(tileIndex, ": ", str_remove(tileName, "\\.tif"), " lacks a near infrared band\n"))
    next
  }
  tileCellCount = nrow(tileOrthoimage) * ncol(tileOrthoimage)
  tileOrthoimageCrs = crs(tileOrthoimage, describe = TRUE)
  #tileOrthoimagePointCounts = rast(file.path(orthoimageSourcePath, "nPoints", tileName)
  tileStatisticsTibble = tibble(crds(tileOrthoimage, df = TRUE, na.rm = FALSE)) %>%
    mutate(red = as.vector(tileOrthoimage$red),
           green = as.vector(tileOrthoimage$green),
           blue = as.vector(tileOrthoimage$blue),
           nir = as.vector(tileOrthoimage$nearInfrared),
           #intensitySecondReturn = replace_na(intensitySecondReturn, 0), # if no LiDAR hits, consider second return intensity to be zero
           brvi = (nir / (green + 0.1 * red) - blue / (red + 0.5 * green)) / (nir / (green + 0.1 * red) + blue / (red + 0.5 * green)),
           #chlorophyllVegetation = nir * as.numeric(red) / green^2,
           #gndvi = (nir - green) / (nir + green),
           #luminosity = 0.299 * red + 0.587 * green + 0.114 * blue, # NTSC, ITU BT.610
           mari = nir * (1/green - 1/red),
           #mcari = 1.5 * (2.5 * (nir - red) - 1.3 * (nir - green)) / sqrt((2 * nir + 1)^2 - (6 * nir - 5 * red) - 0.5),
           #mexg = 1.62 * green - 0.884 * red - 0.311 * blue,
           #mgrv = (green^2 - red^2) / (green^2 + red^2),
           msavi = (2 * nir + 1 - sqrt(2 * (2 * nir + 1)^2 - 8 * (nir - red))) / 2,
           #msr = (nir/red - 1) / sqrt(nir/red + 1))
           #ndgb = (green - blue) / (green + blue),
           #ndgr = (green - red) / (green + red),
           #normalizedGreen = green / (nir + red + green),
           #rgbv = (green^2 - red * as.numeric(blue)) / (green^2 + red * as.numeric(blue)),
           #savi = (1 + 0.5) * (nir - red) / (nir + red + 0.5),
           hasNA = is.na(brvi) | is.na(mari) | is.na(msavi)) %>%
    select(-red, -green, -blue, -nir) # trim memory consumption

  if ("scanAngleCosine" %in% randomForestFit$forest$independent.variable.names)
  {
    tileScanAngle = rast(file.path(orthoimageSourcePath, "scanAngle", tileName))
    tileScanAngleCrs = crs(tileOrthoimage, describe = TRUE)
    if ((tileOrthoimageCrs$authority != tileScanAngleCrs$authority) | (tileOrthoimageCrs$code != tileScanAngleCrs$code))
    {
      stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match scan angle CRS ", tileScanAngleCrs$authority, ":", tileDsmCrs$code, "."))
    }
    if ((nrow(tileOrthoimage) != nrow(tileScanAngle) | (ncol(tileOrthoimage) != ncol(tileScanAngle))))
    {
      stop(paste0(nrow(tileScanAngle), " by ", ncol(tileScanAngle), " scan angle tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    tileStatisticsTibble %<>% mutate(scanAngleCosine = cos(pi/180 * as.vector(tileScanAngle$scanAngleMeanAbsolute)))
    rm(tileScanAngle) # reduce memory footprint
  }
  
  tileDsm = rast(file.path(dsmSourcePath, tileName))
  tileDsmCrs = crs(tileDsm, describe = TRUE)
  if ((tileOrthoimageCrs$authority != tileDsmCrs$authority) | (tileOrthoimageCrs$code != tileDsmCrs$code))
  {
    stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match DSM CRS ", tileDsm$authority, ":", tileDsmCrs$code, "."))
  }
  if ((nrow(tileOrthoimage) != nrow(tileDsm) | (ncol(tileOrthoimage) != ncol(tileDsm))))
  {
    stop(paste0(nrow(tileDsm), " by ", ncol(tileDsm), " DSM tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
  }
  tileStatisticsTibble %<>% mutate(dsm = as.vector(tileDsm$dsm)) # needed for image center kNN
                                   #cmm3 = as.vector(tileDsm$cmm3), 
                                   #chm = replace_na(as.vector(tileDsm$chm), 0)) # if no LiDAR hits, assume DSM = DTM => CHM = 0
  rm(tileDsm) # reduce memory footprint
  
  tileDtm = focal(rast(file.path(dtmSourcePath, tileName)), w = 3, na.policy = "only") # interpolate any NA cells in case the DSM also lacks data, DTM is expected to be null at the northernmost row of tiles without another tile to the north of them due to limitations in GDAL's bilinear interpolation
  tileDtmCrs = crs(tileDtm, describe = TRUE)
  if ((tileOrthoimageCrs$authority != tileDtmCrs$authority) | (tileOrthoimageCrs$code != tileDtmCrs$code))
  {
    stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match DTM CRS ", tileDtmCrs$authority, ":", tileDtmCrs$code, "."))
  } 
  if ((nrow(tileOrthoimage) != nrow(tileDtm) | (ncol(tileOrthoimage) != ncol(tileDtm))))
  {
    stop(paste0(nrow(tileDtm), " by ", ncol(tileDtm), " DSM tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
  }
  tileStatisticsTibble %<>% mutate(dsm = if_else(is.na(dsm), as.vector(tileDtm), dsm))
  rm(tileDtm) # reduce memory footprint
  
  imageCenterIndex = knnx.index(imageCentersForKnn, tileStatisticsTibble %>% select(x, y, dsm), k = 1)
  tileStatisticsTibble %<>% mutate(sunAzimuth = imageSunPositions$azimuth[imageCenterIndex], 
                                   sunZenithAngleCosine = cos(pi/180 * (90 - imageSunPositions$elevation[imageCenterIndex]))) %>%
                                   # view angles not currently used
                                   #deltaX = imageCentersForKnn$x[imageCenterIndex] - x,
                                   #deltaY = imageCentersForKnn$y[imageCenterIndex] - y,
                                   #deltaZ = imageCentersForKnn$z[imageCenterIndex] - dsm,
                                   #viewAzimuth = -180/pi * (atan2(deltaY, deltaX) - pi/2),
                                   #viewAzimuth = if_else(viewAzimuth > 0, viewAzimuth, 360 + viewAzimuth),
                                   #viewZenithAngle = 180/pi * atan2(sqrt(deltaX^2 + deltaY^2), deltaZ),
                                   #viewZenithAngleCosine = cos(pi/180 * viewZenithAngle)) %>%
                                   #viewElevation = 90 - viewZenithAngle,
                                   #viewAzimuthSunRelative = sunAzimuth - viewAzimuth, # 0 = forward scatter, ±180 = backscatter, absolute value broken out separately to allow for asymmetric BRDF
                                   #viewAzimuthSunRelative = if_else(viewAzimuthSunRelative > 180, 360 - viewAzimuthSunRelative, if_else(viewAzimuthSunRelative < -180, 360 + viewAzimuthSunRelative, viewAzimuthSunRelative)), # clamp to [0, ±180] to constrain training complexity
                                   #viewAzimuthSunRelativeAbsolute = abs(viewAzimuthSunRelative)) %>%
    select(-x, -y) # trim memory footprint
    #select(-deltaX, -deltaY, -deltaZ, -viewZenithAngle)
  rm(imageCenterIndex) # reduce memory footprint
  
  if ("nAerial" %in% randomForestFit$forest$independent.variable.names)
  {
    tileDsmPointCounts = rast(file.path(dsmPointsSourcePath, tileName))
    tileDsmPointCountsCrs = crs(tileDsmPointCounts, describe = TRUE)
    if ((tileOrthoimageCrs$authority != tileDsmPointCountsCrs$authority) | (tileOrthoimageCrs$code != tileDsmPointCountsCrs$code))
    {
      stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match DSM point counts' CRS ", tileDsmPointCountsCrs$authority, ":", tileDsmPointCountsCrs$code, "."))
    }
    if ((nrow(tileOrthoimage) != nrow(tileDsmPointCounts) | (ncol(tileOrthoimage) != ncol(tileDsmPointCounts))))
    {
      stop(paste0(nrow(tileDsmPointCounts), " by ", ncol(tileDsmPointCounts), " DSM point count tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    tileStatisticsTibble %<>% mutate(nAerial = as.vector(tileDsmPointCounts$nAerial))
    rm(tileDsmPointCounts) # reduce memory footprint
  }
  
  if (sum(c("cmmAspectSunRelativeCosine", "dsmAspectSunRelativeCosine", "cmmSlope3", "dsmSlope") %in% randomForestFit$forest$independent.variable.names) > 0)
  {
    tileDsmSlopeAspect = rast(file.path(dsmSlopeAspectSourcePath, tileName))
    tileDsmSlopeAspectCrs = crs(tileDsmSlopeAspect, describe = TRUE)
    if ((tileOrthoimageCrs$authority != tileDsmSlopeAspectCrs$authority) | (tileOrthoimageCrs$code != tileDsmSlopeAspectCrs$code))
    {
      stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match DSM slope and aspect's CRS ", tileDsmSlopeAspectCrs$authority, ":", tileDsmSlopeAspectCrs$code, "."))
    }
    if ((nrow(tileOrthoimage) != nrow(tileDsmSlopeAspect) | (ncol(tileOrthoimage) != ncol(tileDsmSlopeAspect))))
    {
      stop(paste0(nrow(tileDsmSlopeAspect), " by ", ncol(tileDsmSlopeAspect), " DSM slope and aspect tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    if ("cmmAspectSunRelativeCosine" %in% randomForestFit$forest$independent.variable.names)
    {
      tileStatisticsTibble %<>% mutate(cmmAspectSunRelative = sunAzimuth - as.vector(tileDsmSlopeAspect$cmmAspect3),
                                       cmmAspectSunRelative = if_else(cmmAspectSunRelative > 180, 360 - cmmAspectSunRelative, if_else(cmmAspectSunRelative < -180, 360 + cmmAspectSunRelative, cmmAspectSunRelative)),
                                       cmmAspectSunRelativeCosine = cos(pi / 180 * cmmAspectSunRelative),
                                       hasNA = hasNA | is.na(cmmAspectSunRelativeCosine)) %>%
        select(-cmmAspectSunRelative)
    }
    if ("dsmAspectSunRelativeCosine" %in% randomForestFit$forest$independent.variable.names)
    {
      tileStatisticsTibble %<>% mutate(dsmAspectSunRelative = sunAzimuth - as.vector(tileDsmSlopeAspect$dsmAspect),
                                       dsmAspectSunRelative = if_else(dsmAspectSunRelative > 180, 360 - dsmAspectSunRelative, if_else(dsmAspectSunRelative < -180, 360 + dsmAspectSunRelative, dsmAspectSunRelative)),
                                       dsmAspectSunRelativeCosine = cos(pi / 180 * dsmAspectSunRelative),
                                       hasNA = hasNA | is.na(dsmAspectSunRelativeCosine)) %>%
        select(-dsmAspectSunRelative)
    }
    if ("cmmSlope3" %in% randomForestFit$forest$independent.variable.names)
    {
      tileStatisticsTibble %<>% mutate(cmmSlope3 = as.vector(tileDsmSlopeAspect$cmmSlope3),
                                       hasNA = hasNA | is.na(cmmSlope3))
    }
    if ("dsmSlope3" %in% randomForestFit$forest$independent.variable.names)
    {
      tileStatisticsTibble %<>% mutate(dsmSlope = as.vector(tileDsmSlopeAspect$dsmSlope),
                                       hasNA = hasNA | is.na(dsmSlope))
    }
    rm(tileDsmSlopeAspect) # reduce memory footprint
  }
  
  # 10m slope and aspect not currently used
  #tileAspect100cosine = resample(dtmAspect100cosine, tileOrthoimage, method = "bilinear")
  #tileAspect100cosineCrs = crs(tileAspect100cosine, describe = TRUE)
  #if ((tileOrthoimageCrs$authority != tileAspect100cosineCrs$authority) | (tileOrthoimageCrs$code != tileAspect100cosineCrs$code))
  #{
  #  stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match cos(aspect) CRS ", tileAspect100cosineCrs$authority, ":", tileAspect100cosineCrs$code, "."))
  #}
  #if ((nrow(tileOrthoimage) != nrow(tileAspect100cosineCrs) | (ncol(tileOrthoimage) != ncol(tileAspect100cosineCrs))))
  #{
  #  stop(paste0(nrow(tileAspect100cosineCrs), " by ", ncol(tileAspect100cosineCrs), " 10 m cos(aspect) tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
  #}
  #tileAspect100sine = resample(dtmAspect100sine, tileOrthoimage, method = "bilinear")
  #tileAspect100sineCrs = crs(tileAspect100sine, describe = TRUE)
  #if ((tileOrthoimageCrs$authority != tileAspect100sineCrs$authority) | (tileOrthoimageCrs$code != tileAspect100sineCrs$code))
  #{
  #  crs(tileAspect100sine) = crs(tileOrthoimage)
  #}
  #if ((nrow(tileOrthoimage) != nrow(tileAspect100sine) | (ncol(tileOrthoimage) != ncol(tileAspect100sine))))
  #{
  #  stop(paste0(nrow(tileAspect100sine), " by ", ncol(tileAspect100sine), " 10 m sin(aspect) tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
  #}
  #tileStatisticsTibble %<>% mutate(aspect100 = 180/pi * atan2(as.vector(tileAspect100sine, tileAspect100cosine),
  #                                 aspect100 = if_else(aspect100 > 0, aspect100, 360 + aspect100),
  #                                 aspect100sunRelative = sunAzimuth - aspect100, 
  #                                 aspect100sunRelative = if_else(aspect100sunRelative > 180, 360 - aspect100sunRelative, if_else(aspect100sunRelative < -180, 360 + aspect100sunRelative, aspect100sunRelative))))
  #rm(tileAspect100cosine, tileAspect100sine) # reduce memory footprint
  
  if (classificationOptions$gridMetricsResolution == 1.8)
  {
    tileGridMetrics018 = resample(gridMetrics018, tileOrthoimage, method = classificationOptions$gridMetricsResamplingMethod)
    tileGridMetrics018Crs = crs(tileGridMetrics018, describe = TRUE)
    if ((tileOrthoimageCrs$authority != tileGridMetrics018Crs$authority) | (tileOrthoimageCrs$code != tileGridMetrics018Crs$code))
    {
      crs(tileGridMetrics018) = crs(tileOrthoimage)
    }
    if ((nrow(tileOrthoimage) != nrow(tileGridMetrics018) | (ncol(tileOrthoimage) != ncol(tileGridMetrics018))))
    {
      stop(paste0(nrow(tileGridMetrics018), " by ", ncol(tileGridMetrics018), " 1.8 m grid metrics tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    tileStatisticsTibble %<>% mutate(#hMean018 = as.vector(tileGridMetrics018$zMean018) - as.vector(tileGridMetrics018$zGroundMean018), 
                                     #hQ10_018 = as.vector(tileGridMetrics018$zQ10_018) - as.vector(tileGridMetrics018$zGroundMean018),
                                     hQ20_018 = as.vector(tileGridMetrics018$zQ20_018) - as.vector(tileGridMetrics018$zGroundMean018),
                                     hQ90_018 = as.vector(tileGridMetrics018$zQ90_018) - as.vector(tileGridMetrics018$zGroundMean018),
                                     intensityQ10_018 = as.vector(tileGridMetrics018$intensityQ10_018),
                                     #intensityQ20_018 = as.vector(tileGridMetrics018$intensityQ20_018),
                                     #intensityQ40_018 = as.vector(tileGridMetrics018$intensityQ40_018),
                                     intensityQ70_018 = as.vector(tileGridMetrics018$intensityQ70_018),
                                     #intensityMax018 = as.vector(tileGridMetrics018$intensityMax018),
                                     #intensityMean018 = as.vector(tileGridMetrics018$intensityMean018),
                                     intensitySkew018 = as.vector(tileGridMetrics018$intensitySkew018),
                                     pGround018 = as.vector(tileGridMetrics018$pGround018),
                                     hasNA = hasNA | is.na(intensityQ10_018) | is.na(intensityQ70_018) | is.na(intensitySkew018) | is.na(hQ90_018) | is.na(hQ20_018) | is.na(pGround018))
    rm(tileGridMetrics018) # reduce memory footprint
  } else if (classificationOptions$gridMetricsResolution == 3.0) {
    tileGridMetrics030 = resample(gridMetrics030, tileOrthoimage, method = classificationOptions$gridMetricsResamplingMethod)
    tileGridMetrics030Crs = crs(tileGridMetrics030, describe = TRUE)
    if ((tileOrthoimageCrs$authority != tileGridMetrics030Crs$authority) | (tileOrthoimageCrs$code != tileGridMetrics030Crs$code))
    {
      stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match grid metrics CRS ", tileGridMetrics030Crs$authority, ":", tileGridMetrics030Crs$code, "."))
    }
    if ((nrow(tileOrthoimage) != nrow(tileGridMetrics030) | (ncol(tileOrthoimage) != ncol(tileGridMetrics030))))
    {
      stop(paste0(nrow(tileGridMetrics030), " by ", ncol(tileGridMetrics030), " 3.0 m grid metrics tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    tileStatisticsTibble %<>% mutate(hMean030 = as.vector(tileGridMetrics030$zMean030) - as.vector(tileGridMetrics030$zGroundMean030), 
                                     #hQ10_030 = as.vector(tileGridMetrics030$zQ10_030) - as.vector(tileGridMetrics030$zGroundMean030),
                                     #intensityQ40_030 = as.vector(tileGridMetrics030$intensityQ40_030),
                                     #intensityMax030 = as.vector(tileGridMetrics030$intensityMax030),
                                     intensityMean030 = as.vector(tileGridMetrics030$intensityMean030),
                                     #intensitySkew030 = as.vector(tileGridMetrics030$intensitySkew030),
                                     pGround030 = as.vector(tileGridMetrics030$pGround030),
                                     hasNA = hasNA | is.na(intensitySkew030))
    rm(tileGridMetrics030) # reduce memory footprint
  } else if (classificationOptions$gridMetricsResolution == 4.6) {
    tileGridMetrics046 = resample(gridMetrics046, tileOrthoimage, method = classificationOptions$gridMetricsResamplingMethod)
    tileGridMetrics046Crs = crs(tileGridMetrics046, describe = TRUE)
    if ((tileOrthoimageCrs$authority != tileGridMetrics046Crs$authority) | (tileOrthoimageCrs$code != tileGridMetrics046Crs$code))
    {
      stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match grid metrics CRS ", tileGridMetrics046Crs$authority, ":", tileGridMetrics046Crs$code, "."))
    }
    if ((nrow(tileOrthoimage) != nrow(tileGridMetrics046) | (ncol(tileOrthoimage) != ncol(tileGridMetrics046))))
    {
      stop(paste0(nrow(tileGridMetrics046), " by ", ncol(tileGridMetrics046), " 4.6 m grid metrics tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    tileStatisticsTibble %<>% mutate(hMean046 = as.vector(tileGridMetrics046$zMean046) - as.vector(tileGridMetrics046$zGroundMean046), 
                                     hQ10_046 = as.vector(tileGridMetrics046$zQ10_046) - as.vector(tileGridMetrics046$zGroundMean046),
                                     intensityQ40_046 = as.vector(tileGridMetrics046$intensityQ40_046),
                                     intensityMax046 = as.vector(tileGridMetrics046$intensityMax046),
                                     intensitySkew046 = as.vector(tileGridMetrics046$intensitySkew046),
                                     pGround046 = as.vector(tileGridMetrics046$pGround046))
    rm(tileGridMetrics046) # reduce memory footprint
  } else if (classificationOptions$gridMetricsResolution == 10.0) {
    tileGridMetrics100 = resample(gridMetrics100, tileOrthoimage, method = classificationOptions$gridMetricsResamplingMethod)
    tileGridMetrics100Crs = crs(tileGridMetrics100, describe = TRUE)
    if ((tileOrthoimageCrs$authority == tileGridMetrics100Crs$authority) & (tileOrthoimageCrs$code == tileGridMetrics100Crs$code))
    {
      stop(paste0("Orthoimage CRS ", tileOrthoimageCrs$authority, ":", tileOrthoimageCrs$code, " does not match grid metrics CRS ", tileGridMetrics100Crs$authority, ":", tileGridMetrics100Crs$code, "."))
    }
    if ((nrow(tileOrthoimage) != nrow(tileGridMetrics100) | (ncol(tileOrthoimage) != ncol(tileGridMetrics100))))
    {
      stop(paste0(nrow(tileGridMetrics100), " by ", ncol(tileGridMetrics100), " 10.0 m grid metrics tile is not the same size as ", ncol(tileOrthoimage), " by ", ncol(tileOrthoimage), " orthoimage tile."))
    }
    tileStatisticsTibble %<>% mutate(hMean100 = as.vector(tileGridMetrics100$zMean100) - as.vector(tileGridMetrics100$zGroundMean100), 
                                     hQ10_100 = as.vector(tileGridMetrics100$zQ10_100) - as.vector(tileGridMetrics100$zGroundMean100),
                                     intensityQ40_100 = as.vector(tileGridMetrics100$intensityQ40_100),
                                     intensityMax100 = as.vector(tileGridMetrics100$intensityMax100),
                                     intensitySkew100 = as.vector(tileGridMetrics100$intensitySkew100),
                                     pGround100 = as.vector(tileGridMetrics100$pGround100))
    rm(tileGridMetrics100) # reduce memory footprint
  }
  
  # accommodate ranger by excluding pixels and grid metrics cells without data
  #sum(tileStatisticsTibble$hasNA)
  tileStatisticsTibble %<>% mutate(cellID = 1:tileCellCount) %>% # must establish cell IDs before filtering to place NAs after prediction, also checks stats tibble's ended up with one row per cell
    filter(hasNA == FALSE)
  #colSums(is.na(tileStatisticsTibble))
  #predictorVariables[which(predictorVariables %in% names(tileStatisticsTibble) == FALSE)]

  # predict land cover types for cells with data
  # ranger 0.16.0 can't flow NAs from row with NAs so they're filtered out above.
  #print(tibble(predictor = randomForestFit$forest$independent.variable.names, inData = randomForestFit$finalModel$forest$independent.variable.names %in% names(tileStatisticsTibble)), nrow = length(randomForestFit$finalModel$forest$independent.variable.names))
  tileClassification = predict(randomForestFit, data = tileStatisticsTibble, num.threads = classificationOptions$rangerThreads)
  
  # restore NA entries removed by filtering
  tileClassificationVector = factor(rep(NA, tileCellCount), levels = randomForestFit$forest$levels)
  tileClassificationVector[tileStatisticsTibble$cellID] = tileClassification$predictions

  # write tile classification
  classificationRaster = rast(tileOrthoimage, nlyrs = 1, names = "classification", vals = tileClassificationVector)
  writeRaster(classificationRaster, classificationRasterPath, datatype = "INT1U", overwrite = TRUE) #, gdal = c("COMPRESS=DEFLATE", "PREDICTOR=2", "ZLEVEL=9")
  rm(tileStatisticsTibble) # reduce memory footprint
}

warnings()
cat(paste0("land cover classification over ", length(tileNames), " tiles in ", format(Sys.time() - jobStartTime), ".\n"))

if (classificationOptions$generateVrt)
{
  classificationFilePaths = file.path(dataDestinationPath, list.files(dataDestinationPath, "\\.tif$"))
  classificationVrt = vrt(classificationFilePaths, file.path(dataDestinationPath, paste0(basename(dataDestinationPath), ".vrt")), options = c("-b", 1), overwrite = TRUE, set_names = TRUE)
}