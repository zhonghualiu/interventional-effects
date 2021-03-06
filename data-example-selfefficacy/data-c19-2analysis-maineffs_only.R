source("data-c19-1prep.R")
Data
library("xtable")

(m_names <- grep("M",colnames(Data),value=TRUE))
(p <- length(m_names)) # number of mediators
(l_names <- names(Data)[2:8]) # confounders

OnePtEst <- function(popdata, inv_wt=FALSE) {
  # popdata=Data
  # fit mediator and outcome models to population data ========================
  fit_MY <- list()
  for (varname in c(paste0("M",1:p),"Y")) {
    # exposure group-specific fitted models
    for (aa in 0:1) {
      # conditional on confounders L
      if (varname == "Y") {
        # outcome
        modelformula <- paste0(varname,"~",paste(c(
          # main effects
          paste0("M",1:p),
          # interaction effects
          unlist(sapply(1:(p-1), function(s) paste0("M",s,":M",(s+1):p))),
          # covariates
          l_names),collapse="+"))
      } else {
        ## marginal for each mediator unconditional on other mediators
        modelformula <- paste0(varname,"~",paste(l_names,collapse="+"))
      }
      
      # subset is evaluated in the same way as variables in formula
      if (varname!="Y") {
        fit_MY[[paste0(varname,"_A",aa)]] <- 
          glm(formula=as.formula(modelformula),
              family = gaussian("identity"),
              data=popdata,subset=A==aa)
      } else {
        fit_MY[[paste0(varname,"_A",aa)]] <- 
          glm(formula=as.formula(modelformula),
              family = binomial("logit"),
              data=popdata,subset=A==aa)
      }
      rm(modelformula)
      
      # conditional on other mediators (for joint mediator distribution)
      if (varname %in% paste0("M",2:p)) {
        m_idx <- as.integer(strsplit(varname,"M")[[1]][2])
        m_preds <- c(paste0("M",1:(m_idx-1)),l_names)
        if (m_idx>2) {
          m_preds <- c(
            m_preds,
            # interaction effects
            unlist(sapply(2:(m_idx-1), function(s) paste0("M",1:(s-1),":M",s))))
        }
        modelformula <- paste0(varname,"~",paste(m_preds,collapse="+"))
        fit_MY[[paste0(varname,"condMs_A",aa)]] <- 
          glm(formula=as.formula(modelformula),
              family = gaussian("identity"),
              data=popdata,subset=A==aa)
        rm(modelformula)
      }
    }
  }
  # PS model
  fit_A <- glm(paste0("A~",paste(l_names,collapse="+")), 
               family = binomial("logit"), data = popdata)
  
  # results from fitted to observed data 
  if (FALSE) {
    lapply(fit_MY, "[[", "formula")
    lapply(fit_MY, "[[", "coefficients")
  }
  
  source("funs-MC_Wt.R")
  
  # effect model posited ======================================================
  eff_mod <- as.formula(paste0("Y.a ~ ",paste(c(
    paste0("a",1:p,":I(1-J)"),paste0(c("","a0:","a1:a2:a3:"),"J"),
    l_names),collapse="+")))
  
  res_ie <- list() # for saving results
  
  if (inv_wt==TRUE) {
    # weighted estimator
    res <- OneWTestimator(Data=popdata,
                          fit_M=fit_MY[grep("M",names(fit_MY),value=TRUE)],
                          fit_A=fit_A,Lnames=l_names,eff_mod)
    res_ie[["wt"]] <- res
    rm(res)
  }
  
  # MC estimator
  res <- OneMCestimator(Data=popdata,mc_draws=100,
                        fit_MY=fit_MY,Lnames=l_names,eff_mod)
  res_ie[["mc"]] <- res
  rm(res)
  
  return( res_ie )
}

# consider all permutations of mediator ordering ==============================
## appropriate only for small number of mediators
allperms <- expand.grid(lapply(1:p, function (x) p:1))
allperms <- allperms[apply(allperms, 1, function(x) 
  length(unique(x))==length(x)),]
row.names(allperms) <- colnames(allperms) <- NULL

ie_list <- list()
for (mo in 1:nrow(allperms)) {
  neworder <- as.integer(allperms[mo,])
  newdata <- data.table(Data)
  setcolorder(newdata,c("id",l_names,paste0("M",neworder),"Y"))
  setnames(newdata,paste0("M",neworder),paste0("M",1:3))
  res <- OnePtEst(newdata,inv_wt=TRUE)
  # relabel to original mediator names
  res_names <- names(res$mc)
  for (s in 1:p) {
    res_names <- gsub(paste0("a",s),m_labels[neworder][s],res_names)
  }
  res_names <- gsub("I(1 - J):","",res_names,fixed=TRUE)
  res_names <- gsub(":I(1 - J)","",res_names,fixed=TRUE)
  names(res$mc) <- names(res$wt$eff_coef) <- res_names

  # bootstrap CIs 
  n <- nrow(Data)
  nboots <- n
  res_boot <- lapply(1:nboots, function(idx) {
    bootdat <- newdata[sample(n,n,TRUE),]
    bootdat$id <- 1:n
    bootres <- OnePtEst(bootdat,inv_wt=FALSE)
    # relabel to original mediator names
    names(bootres$mc) <- res_names
    return( bootres$mc )
  })
  
  ie_list[[mo]] <- c(res, list(res_boot))
  cat(neworder,"\n")
}
save(ie_list,file="data-c19-boots-maineffs_only.Rdata")
q()

# results =====================================================================
library("coxed")
load(file="data-c19-boots-maineffs_only.Rdata")
res_all <- list()  
for (mo in 1:length(ie_list)) {
  res_iw <- ie_list[[mo]]$wt
  res <- ie_list[[mo]]$mc
  res_boot <- ie_list[[mo]][[3]]
  res_boot <- do.call(cbind,res_boot)
  ## inference for certain linear combinations of parameters
  cond_effs <- function(x) {
    ie <- sapply(m_labels, function(m) as.numeric(x[m]))
    c(ie,"mu"=as.numeric(x[length(x)]-sum(ie)),"de"=as.numeric(x["J:a0"]))
  }
  res <- cond_effs(res)
  res_iw$eff_coef <- cond_effs(res_iw$eff_coef)
  res_boot <- apply(res_boot, 2, cond_effs)
  res_ci <- data.frame(t(apply(res_boot,1,function(boots) {
    coxed::bca(boots[!is.na(boots)], conf.level=0.95)
  })))
  colnames(res_ci) <- c("l","u")
  res_ci <- cbind("perm"=mo,"wt"=res_iw$eff_coef,"mc"=res,res_ci)
  for (s in 1:3) {
    res_all[[m_labels[s]]] <- c(
      res_all[[m_labels[s]]],
      list(res_ci[grepl(m_labels[s],rownames(res_ci)),]))
  }
  res_all[["mu"]] <- c(
    res_all[["mu"]],list(res_ci[grepl("mu",rownames(res_ci)),]))
  res_all[["de"]] <- c(
    res_all[["de"]],list(res_ci[grepl("de",rownames(res_ci)),]))
}
## boxplots of weights
pdf("plot-res-weights-maineffs_only.pdf",width=6,height=4)
boxplot(log10(W)~a.i,data=res_iw$weights[res_iw$weights$W>0],
        xlab="Row in duplicated data",ylab="Weights (log-transformed)",
        main="Weights for estimating interventional (in)direct effects")
dev.off()

## results for some ordered indices
xtable(rbind(
  res_all$reexperiencing[[1]],
  res_all$avoidance[[1]],
  res_all$hyperarousal[[1]],
  res_all$mu[[1]],
  res_all$de[[1]]
  )[,-1])

res_perm <- NULL
for (eff in 1:length(res_all)) {
  res_tmp <- data.table(do.call(rbind,lapply(res_all[[eff]], function(x) 
    cbind("eff"=rownames(x),x))))
  setkey(res_tmp)
  res_perm <- rbind(res_perm,res_tmp)
  rm(res_tmp)
}
setkey(res_perm)
print(xtable(res_perm[,as.list(c(range(mc),range(l),range(u))),by=eff]),
      include.rownames=FALSE)
