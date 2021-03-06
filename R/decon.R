#' @title Contamination estimation with decontX
#'
#' @description Identifies contamination from factors such as ambient RNA
#' in single cell genomic datasets.
#'
#' @name decontX
#'
#' @param x A numeric matrix of counts or a \linkS4class{SingleCellExperiment}
#' with the matrix located in the assay slot under \code{assayName}.
#' Cells in each batch will be subsetted and converted to a sparse matrix
#' of class \code{dgCMatrix} from package \link{Matrix} before analysis.
#' @param assayName Character. Name of the assay to use if \code{x} is a
#' \linkS4class{SingleCellExperiment}.
#' @param z Numeric or character vector. Cell cluster labels. If NULL,
#' Celda will be used to reduce the dimensionality of the dataset
#' to 'L' modules, '\link[uwot]{umap}' from the 'uwot' package
#' will be used to further reduce the dataset to 2 dimenions and
#' the '\link[dbscan]{dbscan}' function from the 'dbscan' package
#' will be used to identify clusters of broad cell types. Default NULL.
#' @param batch Numeric or character vector. Batch labels for cells.
#' If batch labels are supplied, DecontX is run on cells from each
#' batch separately. Cells run in different channels or assays
#' should be considered different batches. Default NULL.
#' @param maxIter Integer. Maximum iterations of the EM algorithm. Default 500.
#' @param convergence Numeric. The EM algorithm will be stopped if the maximum
#' difference in the contamination estimates between the previous and
#' current iterations is less than this. Default 0.001.
#' @param iterLogLik Integer. Calculate log likelihood every 'iterLogLik'
#' iteration. Default 10.
#' @param delta Numeric. Symmetric Dirichlet concentration parameter
#' to initialize theta. Default 10.
#' @param varGenes Integer. The number of variable genes to use in
#' Celda clustering. Variability is calcualted using
#' \code{\link[scran]{modelGeneVar}} function from the 'scran' package.
#' Used only when z is not provided. Default 5000.
#' @param L Integer. Number of modules for Celda clustering. Used to reduce
#' the dimensionality of the dataset before applying UMAP and dbscan.
#' Used only when z is not provided. Default 50.
#' @param dbscanEps Numeric. The clustering resolution parameter
#' used in '\link[dbscan]{dbscan}' to estimate broad cell clusters.
#' Used only when z is not provided. Default 1.
#' @param seed Integer. Passed to \link[withr]{with_seed}. For reproducibility,
#'  a default value of 12345 is used. If NULL, no calls to
#'  \link[withr]{with_seed} are made.
#' @param logfile Character. Messages will be redirected to a file named
#'  `logfile`. If NULL, messages will be printed to stdout.  Default NULL.
#' @param verbose Logical. Whether to print log messages. Default TRUE.
#'
#' @return If \code{x} is a matrix-like object, a list will be returned
#' with the following items:
#' \describe{
#' \item{\code{decontXcounts}:}{The decontaminated matrix. Values obtained
#' from the variational inference procedure may be non-integer. However,
#' integer counts can be obtained by rounding,
#' e.g. \code{round(decontXcounts)}.}
#' \item{\code{contamination}:}{Percentage of contamination in each cell.}
#' \item{\code{estimates}:}{List of estimated parameters for each batch. If z
#' was not supplied, then the UMAP coordinates used to generated cell
#' cluster labels will also be stored here.}
#' \item{\code{z}:}{Cell population/cluster labels used for analysis.}
#' \item{\code{runParams}:}{List of arguments used in the function call.}
#' }
#'
#' If \code{x} is a \linkS4class{SingleCellExperiment}, then the decontaminated
#' counts will be stored as an assay and can be accessed with
#' \code{decontXcounts(x)}. The contamination values and cluster labels
#' will be stored in \code{colData(x)}. \code{estimates} and \code{runParams}
#' will be stored in \code{metadata(x)$decontX}. If z was not supplied, then
#' the UMAPs used to generated cell cluster labels will be stored in
#' \code{reducedDims} slot in \code{x}
#'
#' @examples
#' s <- simulateContaminatedMatrix()
#' result <- decontX(s$observedCounts, s$z)
#' contamination <- colSums(s$observedCounts - s$nativeCounts) /
#'   colSums(s$observedCounts)
#' plot(contamination, result$contamination)
NULL

#' @export
setGeneric("decontX", function(x, ...) standardGeneric("decontX"))


#########################
# Setting up S4 methods #
#########################


#' @export
#' @rdname decontX
setMethod("decontX", "SingleCellExperiment", function(x,
                                                      assayName = "counts",
                                                      z = NULL,
                                                      batch = NULL,
                                                      maxIter = 500,
                                                      delta = 10,
                                                      convergence = 0.001,
                                                      iterLogLik = 10,
                                                      varGenes = 5000,
                                                      dbscanEps = 1,
                                                      L = 50,
                                                      seed = 12345,
                                                      logfile = NULL,
                                                      verbose = TRUE) {
  mat <- SummarizedExperiment::assay(x, i = assayName)
  result <- .decontX(
    counts = mat,
    z = z,
    batch = batch,
    maxIter = maxIter,
    convergence = convergence,
    iterLogLik = iterLogLik,
    delta = delta,
    varGenes = varGenes,
    L = L,
    dbscanEps = dbscanEps,
    seed = seed,
    logfile = logfile,
    verbose = verbose
  )

  ## Add results into column annotation
  colData(x) <- cbind(colData(x),
    decontX_Contamination = result$contamination,
    decontX_Clusters = result$z
  )

  ## Put estimated UMAPs into SCE if z was estimated with Celda/UMAP
  if (is.null(result$runParams$z)) {
    batchIndex <- unique(result$runParams$batch)
    if (length(batchIndex) > 1) {
      for (i in batchIndex) {

        ## Each individual UMAP will only be for one batch so need
        ## to put NAs in for cells in other batches
        tempUMAP <- matrix(NA, ncol = 2, nrow = ncol(mat))
        tempUMAP[result$runParams$batch == i, ] <- result$estimates[[i]]$UMAP
        colnames(tempUMAP) <- c("UMAP_1", "UMAP_2")
        rownames(tempUMAP) <- colnames(mat)

        SingleCellExperiment::reducedDim(
          x,
          paste("decontX", i, "UMAP", sep = "_")
        ) <- tempUMAP
      }
    } else {
      SingleCellExperiment::reducedDim(x, "decontX_UMAP") <-
        result$estimates[[batchIndex]]$UMAP
    }
  }


  ## Save the rest of the result object into metadata
  decontXcounts(x) <- result$decontXcounts
  result$decontXcounts <- NULL
  metadata(x)$decontX <- result

  return(x)
})

#' @export
#' @rdname decontX
setMethod("decontX", "ANY", function(x,
                                     z = NULL,
                                     batch = NULL,
                                     maxIter = 500,
                                     delta = 10,
                                     convergence = 0.001,
                                     iterLogLik = 10,
                                     varGenes = 5000,
                                     dbscanEps = 1,
                                     L = 50,
                                     seed = 12345,
                                     logfile = NULL,
                                     verbose = TRUE) {
  .decontX(
    counts = x,
    z = z,
    batch = batch,
    maxIter = maxIter,
    convergence = convergence,
    iterLogLik = iterLogLik,
    delta = delta,
    varGenes = varGenes,
    L = L,
    dbscanEps = dbscanEps,
    seed = seed,
    logfile = logfile,
    verbose = verbose
  )
})


## Copied from SingleCellExperiment Package

GET_FUN <- function(exprs_values, ...) {
  (exprs_values) # To ensure evaluation
  function(object, ...) {
    assay(object, i = exprs_values, ...)
  }
}

SET_FUN <- function(exprs_values, ...) {
  (exprs_values) # To ensure evaluation
  function(object, ..., value) {
    assay(object, i = exprs_values, ...) <- value
    object
  }
}

#' @export
setGeneric("decontXcounts", function(object, ...) {
  standardGeneric("decontXcounts")
})

#' @export
setGeneric("decontXcounts<-", function(object, ..., value) {
  standardGeneric("decontXcounts<-")
})

#' @export
setMethod("decontXcounts", "SingleCellExperiment", GET_FUN("decontXcounts"))

#' @export
setReplaceMethod(
  "decontXcounts", c("SingleCellExperiment", "ANY"),
  SET_FUN("decontXcounts")
)




##########################
# Core Decontx Functions #
##########################

.decontX <- function(counts,
                     z = NULL,
                     batch = NULL,
                     maxIter = 200,
                     convergence = 0.001,
                     iterLogLik = 10,
                     delta = 10,
                     varGenes = NULL,
                     L = NULL,
                     dbscanEps = NULL,
                     seed = 12345,
                     logfile = NULL,
                     verbose = TRUE) {
  startTime <- Sys.time()
  .logMessages(paste(rep("-", 50), collapse = ""),
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )
  .logMessages("Starting DecontX",
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )
  .logMessages(paste(rep("-", 50), collapse = ""),
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )

  runParams <- list(
    z = z,
    batch = batch,
    maxIter = maxIter,
    delta = delta,
    convergence = convergence,
    varGenes = varGenes,
    L = L,
    dbscanEps = dbscanEps,
    logfile = logfile,
    verbose = verbose
  )

  totalGenes <- nrow(counts)
  totalCells <- ncol(counts)
  geneNames <- rownames(counts)
  nC <- ncol(counts)
  allCellNames <- colnames(counts)

  ## Set up final deconaminated matrix
  estRmat <- Matrix::Matrix(
    data = 0,
    ncol = totalCells,
    nrow = totalGenes,
    sparse = TRUE,
    dimnames = list(geneNames, allCellNames)
  )

  ## Generate batch labels if none were supplied
  if (is.null(batch)) {
    batch <- rep("all_cells", nC)
  }
  runParams$batch <- batch
  batchIndex <- unique(batch)

  ## Set result lists upfront for all cells from different batches
  logLikelihood <- c()
  estConp <- rep(NA, nC)
  returnZ <- rep(NA, nC)
  resBatch <- list()

  ## Cycle through each sample/batch and run DecontX
  for (bat in batchIndex) {
    if (length(batchIndex) == 1) {
      .logMessages(
        date(),
        ".. Analyzing all cells",
        logfile = logfile,
        append = TRUE,
        verbose = verbose
      )
    } else {
      .logMessages(
        date(),
        " .. Analyzing cells in batch '",
        bat, "'",
        sep = "",
        logfile = logfile,
        append = TRUE,
        verbose = verbose
      )
    }

    zBat <- NULL
    countsBat <- counts[, batch == bat]

    ## Convert to sparse matrix
    if (!inherits(countsBat, "dgCMatrix")) {
      .logMessages(
        date(),
        ".... Converting to sparse matrix",
        logfile = logfile,
        append = TRUE,
        verbose = verbose
      )
      countsBat <- as(countsBat, "dgCMatrix")
    }


    if (!is.null(z)) {
      zBat <- z[batch == bat]
    }
    if (is.null(seed)) {
      res <- .decontXoneBatch(
        counts = countsBat,
        z = zBat,
        batch = bat,
        maxIter = maxIter,
        delta = delta,
        convergence = convergence,
        iterLogLik = iterLogLik,
        logfile = logfile,
        verbose = verbose,
        varGenes = varGenes,
        dbscanEps = dbscanEps,
        L = L,
        seed = seed
      )
    } else {
      withr::with_seed(
        seed,
        res <- .decontXoneBatch(
          counts = countsBat,
          z = zBat,
          batch = bat,
          maxIter = maxIter,
          delta = delta,
          convergence = convergence,
          iterLogLik = iterLogLik,
          logfile = logfile,
          verbose = verbose,
          varGenes = varGenes,
          dbscanEps = dbscanEps,
          L = L,
          seed = seed
        )
      )
    }
    estRmat <- calculateNativeMatrix(
      counts = countsBat,
      native_counts = estRmat,
      theta = res$theta,
      eta = res$eta,
      row_index = seq(nrow(counts)),
      col_index = which(batch == bat),
      phi = res$phi,
      z = as.integer(res$z),
      pseudocount = 1e-20
    )

    resBatch[[bat]] <- list(
      z = res$z,
      phi = res$phi,
      eta = res$eta,
      delta = res$delta,
      theta = res$theta,
      logLikelihood = res$logLikelihood,
      UMAP = res$UMAP,
      z = res$z,
      iteration = res$iteration
    )

    estConp[batch == bat] <- res$contamination
    if (length(batchIndex) > 1) {
      returnZ[batch == bat] <- paste0(bat, "-", res$z)
    } else {
      returnZ[batch == bat] <- res$z
    }

  }
  names(resBatch) <- batchIndex

  returnResult <- list(
    "runParams" = runParams,
    "estimates" = resBatch,
    "decontXcounts" = estRmat,
    "contamination" = estConp,
    "z" = returnZ
  )

  ## Try to convert class of new matrix to class of original matrix
  if (inherits(counts, "dgCMatrix")) {
    .logMessages(
      date(),
      ".. Finalizing decontaminated matrix",
      logfile = logfile,
      append = TRUE,
      verbose = verbose
    )
  }

  if (inherits(counts, c("DelayedMatrix", "DelayedArray"))) {

    ## Determine class of seed in DelayedArray
    seed.class <- unique(DelayedArray::seedApply(counts, class))[[1]]
    if (seed.class == "HDF5ArraySeed") {
      returnResult$decontXcounts <- as(returnResult$decontXcounts, "HDF5Matrix")
    } else {
      if (isTRUE(canCoerce(returnResult$decontXcounts, seed.class))) {
        returnResult$decontXcounts <- as(returnResult$decontXcounts, seed.class)
      }
    }
    returnResult$decontXcounts <-
      DelayedArray::DelayedArray(returnResult$decontXcounts)
  } else {
    try({
        if (canCoerce(returnResult$decontXcounts, class(counts))) {
          returnResult$decontXcounts <-
            as(returnResult$decontXcounts, class(counts))
        }
      },
      silent = TRUE
    )
  }

  endTime <- Sys.time()
  .logMessages(paste(rep("-", 50), collapse = ""),
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )
  .logMessages("Completed DecontX. Total time:",
    format(difftime(endTime, startTime)),
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )
  .logMessages(paste(rep("-", 50), collapse = ""),
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )

  return(returnResult)
}


# This function updates decontamination for one batch
# seed passed to this function is to be furhter passed to
# function .decontxInitializeZ()
.decontXoneBatch <- function(counts,
                             z = NULL,
                             batch = NULL,
                             maxIter = 200,
                             delta = 10,
                             convergence = 0.01,
                             iterLogLik = 10,
                             logfile = NULL,
                             verbose = TRUE,
                             varGenes = NULL,
                             dbscanEps = NULL,
                             L = NULL,
                             seed = 12345) {
  .checkCountsDecon(counts)
  .checkParametersDecon(proportionPrior = delta)

  # nG <- nrow(counts)
  nC <- ncol(counts)
  deconMethod <- "clustering"

  ## Generate cell cluster labels if none are provided
  umap <- NULL
  if (is.null(z)) {
    .logMessages(
      date(),
      ".... Estimating cell types with Celda",
      logfile = logfile,
      append = TRUE,
      verbose = verbose
    )
    ## Always uses clusters for DecontX estimation
    # deconMethod <- "background"

    varGenes <- .processvarGenes(varGenes)
    dbscanEps <- .processdbscanEps(dbscanEps)
    L <- .processL(L)

    celda.init <- .decontxInitializeZ(
      object = counts,
      varGenes = varGenes,
      L = L,
      dbscanEps = dbscanEps,
      verbose = verbose,
      seed = seed,
      logfile = logfile
    )
    z <- celda.init$z
    umap <- celda.init$umap
    colnames(umap) <- c(
      "DecontX_UMAP_1",
      "DecontX_UMAP_2"
    )
    rownames(umap) <- colnames(counts)
  }

  z <- .processCellLabels(z, numCells = nC)
  K <- length(unique(z))

  iter <- 1L
  numIterWithoutImprovement <- 0L
  stopIter <- 3L

  .logMessages(
    date(),
    ".... Estimating contamination",
    logfile = logfile,
    append = TRUE,
    verbose = verbose
  )

  if (deconMethod == "clustering") {
    ## Initialization
    deltaInit <- delta
    theta <- stats::rbeta(
      n = nC,
      shape1 = deltaInit,
      shape2 = deltaInit
    )


    nextDecon <- decontXInitialize(
      counts = counts,
      theta = theta,
      z = z,
      pseudocount = 1e-20
    )
    phi <- nextDecon$phi
    eta <- nextDecon$eta

    ll <- c()
    llRound <- decontXLogLik(
      counts = counts,
      z = z,
      phi = phi,
      eta = eta,
      theta = theta,
      pseudocount = 1e-20
    )

    ## EM updates
    theta.previous <- theta
    converged <- FALSE
    counts.colsums <- Matrix::colSums(counts)
    while (iter <= maxIter & !isTRUE(converged) &
      numIterWithoutImprovement <= stopIter) {

      nextDecon <- decontXEM(
        counts = counts,
        counts_colsums = counts.colsums,
        phi = phi,
        eta = eta,
        theta = theta,
        z = z,
        pseudocount = 1e-20
      )

      theta <- nextDecon$theta
      phi <- nextDecon$phi
      eta <- nextDecon$eta
      delta <- nextDecon$delta

      max.divergence <- max(abs(theta.previous - theta))
      if (max.divergence < convergence) {
        converged <- TRUE
      }
      theta.previous <- theta

      ## Calculate likelihood and check for convergence
      if (iter %% iterLogLik == 0 || converged) {
        llTemp <- decontXLogLik(
          counts = counts,
          z = z,
          phi = phi,
          eta = eta,
          theta = theta,
          pseudocount = 1e-20
        )

        ll <- c(ll, llTemp)

        .logMessages(date(),
          "...... Completed iteration:",
          iter,
          "| converge:",
          signif(max.divergence, 4),
          logfile = logfile,
          append = TRUE,
          verbose = verbose
        )
      }

      iter <- iter + 1L
    }
  }

  #    resConp <- 1 - colSums(nextDecon$estRmat) / colSums(counts)
  resConp <- nextDecon$contamination
  names(resConp) <- colnames(counts)

  return(list(
    "logLikelihood" = ll,
    "contamination" = resConp,
    "theta" = theta,
    "delta" = delta,
    "phi" = phi,
    "eta" = eta,
    "UMAP" = umap,
    "iteration" = iter - 1L,
    "z" = z
  ))
}





# This function calculates the log-likelihood
#
# counts Numeric/Integer matrix. Observed count matrix, rows represent features
# and columns represent cells
# z Integer vector. Cell population labels
# phi Numeric matrix. Rows represent features and columns represent cell
# populations
# eta Numeric matrix. Rows represent features and columns represent cell
# populations
# theta Numeric vector. Proportion of truely expressed transcripts
.deconCalcLL <- function(counts, z, phi, eta, theta) {
  # ll = sum( t(counts) * log( (1-conP )*geneDist[z,] + conP * conDist[z, ] +
  # 1e-20 ) )  # when dist_mat are K x G matrices
  ll <- sum(Matrix::t(counts) * log(theta * t(phi)[z, ] +
    (1 - theta) * t(eta)[z, ] + 1e-20))
  return(ll)
}

# DEPRECATED. This is not used, but is kept as it might be useful in the future
# This function calculates the log-likelihood of background distribution
# decontamination
# bgDist Numeric matrix. Rows represent feature and columns are the times that
# the background-distribution has been replicated.
.bgCalcLL <- function(counts, globalZ, cbZ, phi, eta, theta) {
  # ll <- sum(t(counts) * log(theta * t(cellDist) +
  #        (1 - theta) * t(bgDist) + 1e-20))
  ll <- sum(t(counts) * log(theta * t(phi)[cbZ, ] +
    (1 - theta) * t(eta)[globalZ, ] + 1e-20))
  return(ll)
}


# This function updates decontamination
#  phi Numeric matrix. Rows represent features and columns represent cell
# populations
#  eta Numeric matrix. Rows represent features and columns represent cell
# populations
#  theta Numeric vector. Proportion of truely expressed transctripts
#' @importFrom MCMCprecision fit_dirichlet
.cDCalcEMDecontamination <- function(counts,
                                     phi,
                                     eta,
                                     theta,
                                     z,
                                     K,
                                     delta) {
  ## Notes: use fix-point iteration to update prior for theta, no need
  ## to feed delta anymore

  logPr <- log(t(phi)[z, ] + 1e-20) + log(theta + 1e-20)
  logPc <- log(t(eta)[z, ] + 1e-20) + log(1 - theta + 1e-20)
  Pr.e <- exp(logPr)
  Pc.e <- exp(logPc)
  Pr <- Pr.e / (Pr.e + Pc.e)

  estRmat <- t(Pr) * counts
  rnGByK <- .colSumByGroupNumeric(estRmat, z, K)
  cnGByK <- rowSums(rnGByK) - rnGByK

  counts.cs <- colSums(counts)
  estRmat.cs <- colSums(estRmat)
  estRmat.cs.n <- estRmat.cs / counts.cs
  estCmat.cs.n <- 1 - estRmat.cs.n
  temp <- cbind(estRmat.cs.n, estCmat.cs.n)
  deltaV2 <- MCMCprecision::fit_dirichlet(temp)$alpha

  ## Update parameters
  theta <-
    (estRmat.cs + deltaV2[1]) / (counts.cs + sum(deltaV2))
  phi <- normalizeCounts(rnGByK,
    normalize = "proportion",
    pseudocountNormalize = 1e-20
  )
  eta <- normalizeCounts(cnGByK,
    normalize = "proportion",
    pseudocountNormalize = 1e-20
  )

  return(list(
    "estRmat" = estRmat,
    "theta" = theta,
    "phi" = phi,
    "eta" = eta,
    "delta" = deltaV2
  ))
}

# DEPRECATED. This is not used, but is kept as it might be useful in the
# feature.
# This function updates decontamination using background distribution
.cDCalcEMbgDecontamination <-
  function(counts, globalZ, cbZ, trZ, phi, eta, theta) {
    logPr <- log(t(phi)[cbZ, ] + 1e-20) + log(theta + 1e-20)
    logPc <-
      log(t(eta)[globalZ, ] + 1e-20) + log(1 - theta + 1e-20)

    Pr <- exp(logPr) / (exp(logPr) + exp(logPc))
    Pc <- 1 - Pr
    deltaV2 <-
      MCMCprecision::fit_dirichlet(matrix(c(Pr, Pc), ncol = 2))$alpha

    estRmat <- t(Pr) * counts
    phiUnnormalized <-
      .colSumByGroupNumeric(estRmat, cbZ, max(cbZ))
    etaUnnormalized <-
      rowSums(phiUnnormalized) - .colSumByGroupNumeric(
        phiUnnormalized,
        trZ, max(trZ)
      )

    ## Update paramters
    theta <-
      (colSums(estRmat) + deltaV2[1]) / (colSums(counts) + sum(deltaV2))
    phi <-
      normalizeCounts(phiUnnormalized,
        normalize = "proportion",
        pseudocountNormalize = 1e-20
      )
    eta <-
      normalizeCounts(etaUnnormalized,
        normalize = "proportion",
        pseudocountNormalize = 1e-20
      )

    return(list(
      "estRmat" = estRmat,
      "theta" = theta,
      "phi" = phi,
      "eta" = eta,
      "delta" = deltaV2
    ))
  }





## Make sure provided parameters are the right type and value range
.checkParametersDecon <- function(proportionPrior) {
  if (length(proportionPrior) > 1 | any(proportionPrior <= 0)) {
    stop("'delta' should be a single positive value.")
  }
}


## Make sure provided count matrix is the right type
.checkCountsDecon <- function(counts) {
  if (sum(is.na(counts)) > 0) {
    stop("Missing value in 'counts' matrix.")
  }
  if (is.null(dim(counts))) {
    stop("At least 2 genes need to have non-zero expressions.")
  }
}


## Make sure provided cell labels are the right type
#' @importFrom plyr mapvalues
.processCellLabels <- function(z, numCells) {
  if (length(z) != numCells) {
    stop(
      "'z' must be of the same length as the number of cells in the",
      " 'counts' matrix."
    )
  }
  if (length(unique(z)) < 2) {
    stop(
      "No need to decontaminate when only one cluster",
      " is in the dataset."
    ) # Even though
    # everything runs smoothly when length(unique(z)) == 1, result is not
    # trustful
  }
  if (!is.factor(z)) {
    z <- plyr::mapvalues(z, unique(z), seq(length(unique(z))))
    z <- as.factor(z)
  }
  return(z)
}


## Add two (veried-length) vectors of logLikelihood
addLogLikelihood <- function(llA, llB) {
  lengthA <- length(llA)
  lengthB <- length(llB)

  if (lengthA >= lengthB) {
    llB <- c(llB, rep(llB[lengthB], lengthA - lengthB))
    ll <- llA + llB
  } else {
    llA <- c(llA, rep(llA[lengthA], lengthB - lengthA))
    ll <- llA + llB
  }

  return(ll)
}



## Initialization of cell labels for DecontX when they are not given
.decontxInitializeZ <-
  function(object, # object is either a sce object or a count matrix
           varGenes = 5000,
           L = 50,
           dbscanEps = 1.0,
           verbose = TRUE,
           seed = 12345,
           logfile = NULL) {
    if (!is(object, "SingleCellExperiment")) {
      sce <- SingleCellExperiment::SingleCellExperiment(
        assays =
          list(counts = object)
      )
    }

    sce <- scater::logNormCounts(sce, log = TRUE)
    #sce <- scater::normalize(sce)

    if (nrow(sce) <= varGenes) {
      topVariableGenes <- seq_len(nrow(sce))
    } else if (nrow(sce) > varGenes) {
      sce.var <- scran::modelGeneVar(sce)
      topVariableGenes <- order(sce.var$bio,
        decreasing = TRUE
      )[seq(varGenes)]
    }
    countsFiltered <- as.matrix(SingleCellExperiment::counts(
      sce[topVariableGenes, ]
    ))
    storage.mode(countsFiltered) <- "integer"

    .logMessages(
      date(),
      "...... Collapsing features into",
      L,
      "modules",
      logfile = logfile,
      append = TRUE,
      verbose = verbose
    )
    ## Celda clustering using recursive module splitting
    L <- min(L, nrow(countsFiltered))
    if (is.null(seed)) {
    initialModuleSplit <- recursiveSplitModule(countsFiltered,
      initialL = L, maxL = L, perplexity = FALSE, verbose = FALSE)
    } else {
      with_seed(seed, initialModuleSplit <- recursiveSplitModule(countsFiltered,
        initialL = L, maxL = L, perplexity = FALSE, verbose = FALSE)
    )}
    initialModel <- subsetCeldaList(initialModuleSplit, list(L = L))

    .logMessages(
      date(),
      "...... Reducing dimensionality with UMAP",
      logfile = logfile,
      append = TRUE,
      verbose = verbose
    )
    ## Louvan graph-based method to reduce dimension into 2 cluster
    nNeighbors <- min(15, ncol(countsFiltered))
    # resUmap <- uwot::umap(t(sqrt(fm)), n_neighbors = nNeighbors,
    #    min_dist = 0.01, spread = 1)
    # rm(fm)
    resUmap <- celdaUmap(countsFiltered, initialModel,
      minDist = 0.01, spread = 1, nNeighbors = nNeighbors, seed = seed
    )

    .logMessages(
      date(),
      " ...... Determining cell clusters with DBSCAN (Eps=",
      dbscanEps,
      ")",
      sep = "",
      logfile = logfile,
      append = TRUE,
      verbose = verbose
    )
    # Use dbSCAN on the UMAP to identify broad cell types
    totalClusters <- 1
    while (totalClusters <= 1 & dbscanEps > 0) {
      resDbscan <- dbscan::dbscan(resUmap, dbscanEps)
      dbscanEps <- dbscanEps - (0.25 * dbscanEps)
      totalClusters <- length(unique(resDbscan$cluster))
    }

    return(list(
      "z" = resDbscan$cluster,
      "umap" = resUmap
    ))
  }


## process varGenes
.processvarGenes <- function(varGenes) {
  if (is.null(varGenes)) {
    varGenes <- 5000
  } else {
    if (varGenes < 2 | length(varGenes) > 1) {
      stop("Parameter 'varGenes' must be an integer larger than 1.")
    }
  }
  return(varGenes)
}

## process dbscanEps for resolusion threshold using DBSCAN
.processdbscanEps <- function(dbscanEps) {
  if (is.null(dbscanEps)) {
    dbscanEps <- 1
  } else {
    if (dbscanEps < 0) {
      stop("Parameter 'dbscanEps' needs to be non-negative.")
    }
  }
  return(dbscanEps)
}

## process gene modules L
.processL <- function(L) {
  if (is.null(L)) {
    L <- 50
  } else {
    if (L < 2 | length(L) > 1) {
      stop("Parameter 'L' must be an integer larger than 1.")
    }
  }
  return(L)
}



#########################
# Simulating Data       #
#########################

#' @title Simulate contaminated count matrix
#' @description This function generates a list containing two count matrices --
#'  one for real expression, the other one for contamination, as well as other
#'  parameters used in the simulation which can be useful for running
#'  decontamination.
#' @param C Integer. Number of cells to be simulated. Default to be 300.
#' @param G Integer. Number of genes to be simulated. Default to be 100.
#' @param K Integer. Number of cell populations to be simulated. Default to be
#'  3.
#' @param NRange Integer vector. A vector of length 2 that specifies the lower
#'  and upper bounds of the number of counts generated for each cell. Default to
#'  be c(500, 1000).
#' @param beta Numeric. Concentration parameter for Phi. Default to be 0.5.
#' @param delta Numeric or Numeric vector. Concentration parameter for Theta. If
#'  input as a single numeric value, symmetric values for beta distribution are
#'  specified; if input as a vector of lenght 2, the two values will be the
#'  shape1 and shape2 paramters of the beta distribution respectively.
#' @param seed Integer. Passed to \link[withr]{with_seed}. For reproducibility,
#'  a default value of 12345 is used. If NULL, no calls to
#'  \link[withr]{with_seed} are made.
#' @return A list object containing the real expression matrix and contamination
#'  expression matrix as well as other parameters used in the simulation.
#' @examples
#' contaminationSim <- simulateContaminatedMatrix(K = 3, delta = c(1, 9))
#' contaminationSim <- simulateContaminatedMatrix(K = 3, delta = 1)
#' @export
simulateContaminatedMatrix <- function(C = 300,
                                       G = 100,
                                       K = 3,
                                       NRange = c(500, 1000),
                                       beta = 0.5,
                                       delta = c(1, 2),
                                       seed = 12345) {
  if (is.null(seed)) {
    res <- .simulateContaminatedMatrix(
      C = C,
      G = G,
      K = K,
      NRange = NRange,
      beta = beta,
      delta = delta
    )
  } else {
    with_seed(
      seed,
      res <- .simulateContaminatedMatrix(
        C = C,
        G = G,
        K = K,
        NRange = NRange,
        beta = beta,
        delta = delta
      )
    )
  }

  return(res)
}


.simulateContaminatedMatrix <- function(C = 300,
                                        G = 100,
                                        K = 3,
                                        NRange = c(500, 1000),
                                        beta = 0.5,
                                        delta = c(1, 2)) {
  if (length(delta) == 1) {
    cpByC <- stats::rbeta(
      n = C,
      shape1 = delta,
      shape2 = delta
    )
  } else {
    cpByC <- stats::rbeta(
      n = C,
      shape1 = delta[1],
      shape2 = delta[2]
    )
  }

  z <- sample(seq(K), size = C, replace = TRUE)
  if (length(unique(z)) < K) {
    warning(
      "Only ",
      length(unique(z)),
      " clusters are simulated. Try to increase numebr of cells 'C' if",
      " more clusters are needed"
    )
    K <- length(unique(z))
    z <- plyr::mapvalues(z, unique(z), seq(length(unique(z))))
  }

  NbyC <- sample(seq(min(NRange), max(NRange)),
    size = C,
    replace = TRUE
  )
  cNbyC <- vapply(seq(C), function(i) {
    stats::rbinom(
      n = 1,
      size = NbyC[i],
      p = cpByC[i]
    )
  }, integer(1))
  rNbyC <- NbyC - cNbyC

  phi <- .rdirichlet(K, rep(beta, G))

  ## sample real expressed count matrix
  cellRmat <- vapply(seq(C), function(i) {
    stats::rmultinom(1, size = rNbyC[i], prob = phi[z[i], ])
  }, integer(G))

  rownames(cellRmat) <- paste0("Gene_", seq(G))
  colnames(cellRmat) <- paste0("Cell_", seq(C))

  ## sample contamination count matrix
  nGByK <-
    rowSums(cellRmat) - .colSumByGroup(cellRmat, group = z, K = K)
  eta <- normalizeCounts(counts = nGByK, normalize = "proportion")

  cellCmat <- vapply(seq(C), function(i) {
    stats::rmultinom(1, size = cNbyC[i], prob = eta[, z[i]])
  }, integer(G))
  cellOmat <- cellRmat + cellCmat

  rownames(cellOmat) <- paste0("Gene_", seq(G))
  colnames(cellOmat) <- paste0("Cell_", seq(C))

  return(
    list(
      "nativeCounts" = cellRmat,
      "observedCounts" = cellOmat,
      "NByC" = NbyC,
      "z" = z,
      "eta" = eta,
      "phi" = t(phi)
    )
  )
}
