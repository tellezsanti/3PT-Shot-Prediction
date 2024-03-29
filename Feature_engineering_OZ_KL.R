## Get Three POint Shots
library(jsonlite)
library(dplyr)
library(foreach)
library(doParallel)
library(parallel)
source("_functions.R")
library(iterators)
library(stringr)
library(lubridate)
require(tictoc)
library(ramify)

pathfl = "data/movement_data/"
pathflpbp = "data/pbp/"  # Path to where you have play by play data stored (pbp)

allFiles = list.files(path = pathfl, pattern = "*.json")  # Assuming all the files are already unzipped to Json file.

# Simple Function needed during script
insertRow <- function(existingDF, newrow, r) {
  existingDF[seq(r + 1, nrow(existingDF) + 1), ] <- existingDF[
    seq(r, nrow(existingDF)), ]
  existingDF[r, ] <- newrow
  existingDF
}

##Select which files to run  . . . with 16GB of memory, I was not able to do all 631 games at once
allFiles <- allFiles[11:30]
#allFiles <- allFiles[201:400]
#allFiles <- allFiles[401:631]
#allFiles <- allFiles[1:1]  ##This is for testing

pbp_all = read.csv(paste0(pathflpbp, "2015-16_pbp.csv"))
pbp_all = pbp_all[c('GAME_ID','EVENTNUM','EVENTMSGTYPE','EVENTMSGACTIONTYPE','PERIOD','WCTIMESTRING',
                    'PCTIMESTRING','HOMEDESCRIPTION','NEUTRALDESCRIPTION',
                    'VISITORDESCRIPTION','SCORE',
                    'SCOREMARGIN', 'PERSON1TYPE', 'PLAYER1_ID','PLAYER1_NAME','PLAYER1_TEAM_ID',
                    'PLAYER1_TEAM_CITY','PLAYER1_TEAM_NICKNAME','PLAYER1_TEAM_ABBREVIATION',
                    'PERSON2TYPE', 'PLAYER2_ID','PLAYER2_NAME','PLAYER2_TEAM_ID','PLAYER2_TEAM_CITY',
                    'PLAYER2_TEAM_NICKNAME','PLAYER2_TEAM_ABBREVIATION','PERSON3TYPE', 'PLAYER3_ID',
                    'PLAYER3_NAME','PLAYER3_TEAM_ID','PLAYER3_TEAM_CITY','PLAYER3_TEAM_NICKNAME',
                    'PLAYER3_TEAM_ABBREVIATION')]


storage = list(rep(0, length(allFiles)))
ball_storage = list(rep(0, length(allFiles) * 50))
cat('For Loop reading Json files starts now:')
for (filename in allFiles) {
  #Load game data
  tic()
  filepath = paste0(pathfl,filename)
  all.movements = sportvu_convert_json(filepath)
  cat(paste0(filename,'| imported successfully'))
  toc()
  tic()
  gameid <- sub("00", "", sub(".json", "", filename))
  pbp = pbp_all[pbp_all$GAME_ID == as.integer(gameid), ]
  df_total = NULL
  
  ##Filter down data to ball in the air
  df_game <- all.movements %>%
    # select(-X) %>% 
    filter(player_id == "-1") %>% filter(radius > 8) %>%
    #XY distance to the basket
    mutate(threedist = ifelse(
      x_loc < 47,
      {
        sqrt((x_loc - 5.25) ^ 2 + (y_loc - 25) ^ 2)
      }, {
        sqrt((x_loc - 88.75) ^ 2 + (y_loc - 25) ^ 2)
      })) %>%
    #XYZ distance to the basket
    mutate(threedistz = ifelse(
      x_loc < 47,
      {
        sqrt((x_loc - 5.25) ^ 2 + (y_loc - 25) ^ 2 +
               (radius - 10) ^ 2)
      }, {
        sqrt((x_loc - 88.75) ^ 2 +
               (y_loc - 25) ^ 2 + (radius - 10) ^ 2)
      })) %>% arrange(quarter, desc(game_clock)) %>%
    distinct(game_clock, .keep_all = TRUE)
  
  
  ## Find the start and end of plays when ball is in the air
  shot_break_end <- df_game %>%
    mutate(lead_game_clock = lead(game_clock, n = 1)) %>%
    filter(game_clock - lead_game_clock > 1) %>%
    distinct(game_clock, quarter) %>%
    select(game_clock_end = game_clock, quarter)
  
  shot_break_start <- df_game %>%
    mutate(lag_game_clock = lag(game_clock, n = 1)) %>%
    filter(lag_game_clock - game_clock > 1) %>%
    distinct(game_clock, quarter) %>%
    select(game_clock_start = game_clock, quarter)
  
  ##Creates dataframe with start and end times of ball in the air
  r <- 1
  newrow <- c(df_game$game_clock[1], df_game$quarter[1])  # Start with first
  # time
  length <- nrow(shot_break_start)
  shot_row <- shot_break_start[length, ]
  shot_break_start <- insertRow(shot_break_start, newrow, r)
  shot_break_end <- bind_rows(shot_break_end, shot_row)  # Add the last time
  shot_break <- cbind(shot_break_start, shot_break_end)
  
  ##Now that we have the start/end times, lets start by filtering out our dataset to these times
  ##Also, lets get rid of any plays that are less than 22 feet
  ##Assign a new id to these plays - shot_id
  sumtotal <- NULL
  for (i in 1:nrow(shot_break)) {
    df_event_temp <- df_game %>%
      filter(quarter == shot_break$quarter[i] &
               game_clock <= shot_break$game_clock_start[i] &
               game_clock > shot_break$game_clock_end[i]) %>%
      filter(max(threedist) - min(threedist) > 22)
    if(nrow(df_event_temp) == 0){
      next
    }
    df_event <- df_event_temp %>% 
      mutate(shot_id = i)
    sumtotal <- bind_rows(df_event, sumtotal)
  }
  ##This gives us a dataframe of the ball in air, on plays, where it goes greater than 22 feet
  
  ##The next step is matching this data to the play by play data:
  
  ##This brings in all the 3 points shots in the play by play data
  ##This is one way to bring in additional informaton in
  pbp_shot <- pbp %>%
    select(EVENTNUM, EVENTMSGTYPE, EVENTMSGACTIONTYPE, HOMEDESCRIPTION,
           VISITORDESCRIPTION, PCTIMESTRING, PERIOD, PLAYER1_ID)
  pbp_shot$HOMEDESCRIPTION <- as.character(pbp_shot$HOMEDESCRIPTION)
  pbp_shot$VISITORDESCRIPTION <- as.character(pbp_shot$VISITORDESCRIPTION)
  pbp_shot$threepoint <- ifelse(
    grepl("3PT", pbp_shot$VISITORDESCRIPTION) |
      grepl("3PT", pbp_shot$HOMEDESCRIPTION), 1, 0)
  pbp_shot <- pbp_shot %>% filter(threepoint == 1)
  pbp_shot$game_clock <- period_to_seconds(
    ms(as.character(pbp_shot$PCTIMESTRING)))
  
  sumtotal3 <- NULL
  for (q in 1:4) {
    df_merge <- sumtotal %>% filter(quarter == q)
    if (nrow(df_merge) > 0) {
      events <- unique(df_merge$shot_id)
      pbp_q <- pbp_shot %>% filter(PERIOD == q)
      for (i in 1:length(events)) {
        df_merge2 <- df_merge %>% filter(shot_id == events[i])
        merge_time <- min(df_merge2$game_clock)
        timeb <- ifelse(abs(pbp_q$game_clock - merge_time) < 5, 1,
                        0)  # merges if the pbp time is within 5 seconds
        indexc <- match(1, timeb)
        if (Reduce("+", timeb) > 0) {
          df_merge2$EVENTNUM <- pbp_q$EVENTNUM[indexc]
          df_merge2$EVENTMSGTYPE <- pbp_q$EVENTMSGTYPE[indexc]
          df_merge2$PLAYER1_ID <- pbp_q$PLAYER1_ID[indexc]
        } else {
          df_merge2$EVENTNUM <- 999  # 999 indicates no match
          df_merge2$EVENTMSGTYPE <- 999
          df_merge2$PLAYER1_ID <- 999
        }
        sumtotal3 <- bind_rows(df_merge2, sumtotal3)
      }
    }
  }
  sumtotal3 <- sumtotal3 %>% filter(EVENTMSGTYPE != '999')  # Remove any no
  
  # match plays
  
  ##Now we have a dataframe of 3 point plays from when the ball leaves the shooters hand to when it reaches the basket
  
  ##Finds the point where the ball leaves the shooters hand
  df_startshot <- sumtotal3 %>%
    group_by(shot_id) %>% filter(row_number() == 1) %>% ungroup() %>%
    select(shot_id, EVENTMSGTYPE, game_clock, quarter, PLAYER1_ID,
           shot_clock) %>% arrange(quarter, desc(game_clock))
  
  ########################################### Code by Keming ############################################
  df_startshot$position <- 0
  df_startshot$x_loc <- 0
  df_startshot$y_loc <- 0
  df_startshot$num_team <- 0
  df_startshot$num_defen <- 0
  df_startshot$angle <- 0
  df_startshot$court_zone <- 0
  df_startshot$travel_distance <- 0
  df_startshot$travel_speed <- 0
  
  for (i in 1:nrow(df_startshot)){
    point = all.movements %>%
      filter(game_clock == df_startshot$game_clock[i] & quarter == df_startshot$quarter[i]) %>% 
      distinct(player_id,quarter, game_clock, .keep_all = TRUE)
    target = point[which(df_startshot$PLAYER1_ID[i] == point$player_id),]
    if (nrow(target)==0) next
    df_startshot$position[i] = target$position
    df_startshot$x_loc[i] = target$x_loc
    df_startshot$y_loc[i] = target$y_loc
    # compute angle:
    #basketball coordinates:  x:5.25, y:25
    a = as.vector(c((target$x_loc-5.25),(target$y_loc-25)))
    b = as.vector(c(-5.25,-25))
    angle = (acos( sum(a*b) / ( sqrt(sum(a * a)) * sqrt(sum(b * b)) ) ))/pi * 180
    df_startshot$angle[i] = angle
    
    teammate = point[point$team_id == target$team_id & point$player_id != -1,]
    defenser = point[ -which(point$team_id == target$team_id | point$player_id == -1),]
    c = 0
    for (j in 1:nrow(teammate)){
      if (((teammate$x_loc[j] - target$x_loc)**2 + (teammate$y_loc[j] - target$y_loc)**2) <= 25){
        c = c + 1
      }
    }
    df_startshot$num_team[i] = c-1
    c = 0
    for (j in 1:nrow(defenser)){
      if (((defenser$x_loc[j] - target$x_loc)**2 + (defenser$y_loc[j] - target$y_loc)**2) <= 25){
        c = c + 1
      }
    }
    df_startshot$num_defen[i] = c
  }
  x_loc_trans = df_startshot$x_loc
  df_startshot$x_loc = ifelse(x_loc_trans < 47, x_loc_trans, 94-x_loc_trans)
  angle_trans = df_startshot$angle
  df_startshot$angle = ifelse(angle_trans<=90,angle_trans,180-angle_trans)
  df_startshot$court_zone = ifelse(df_startshot$angle<=30, 'Corner', df_startshot$angle)
  df_startshot$court_zone = ifelse(df_startshot$angle>60, 'High', df_startshot$court_zone)
  df_startshot$court_zone = ifelse(df_startshot$angle<=60&df_startshot$angle>30, 'Medium', df_startshot$court_zone)
  #####################################################################################################
  
  ##loops through each three point play
  for (i in 1:nrow(df_startshot)) {
    
    ##Get start of the play
    df_startplay <- all.movements %>%
      filter(quarter == df_startshot$quarter[i] &
               game_clock >= df_startshot$game_clock[i]) %>%
      filter(player_id == "-1") %>%
      distinct(quarter, game_clock, .keep_all = TRUE) %>%
      arrange(quarter, game_clock) %>% filter(!is.na(shot_clock)) %>%
      mutate(lead_shot_clock = lead(shot_clock, n = 1)) %>%
      filter(shot_clock - lead_shot_clock > 1) %>% head(1)
    ##Get the ball/player data now that we have the start/end time
    if (nrow(df_startplay) > 0) {
      ##Subset down to just data for this play based on length of play
      df_play <- all.movements %>%
        filter(quarter == df_startshot$quarter[i] &
                 game_clock <= (df_startplay$game_clock) &
                 game_clock >= df_startshot$game_clock[i]) %>%
        # df_play <- all.movements %>% filter (quarter==df_startshot$quarter[i] & game_clock <= (df_startshot$game_clock[i]+length_of_play) & game_clock >= df_startshot$game_clock[i]) %>%
        mutate(playid = i) %>%
        distinct(player_id, quarter, game_clock, .keep_all = TRUE) %>%
        arrange(desc(game_clock), player_id)
      #Rotate plays depending upon location of the shot
      if (tail(df_play$x_loc, 1) > 47) {
        df_play <- df_play %>%
          mutate(x_loc = 94 - x_loc) %>% mutate(y_loc = 50 - y_loc)
      }
      df_play$gameid <- gameid
      df_play$EVENTMSGTYPE <- df_startshot$EVENTMSGTYPE[i]  # Adding in some of the pbp data
      df_play$PLAYER1_ID <- df_startshot$PLAYER1_ID[i]
      df_play$shot_id_match_startshot <- df_startshot$shot_id[i]
      df_total <- bind_rows(df_total, df_play)
      
      #########################################################################################################
      #Pancake's code to calculate the travel distance of the shooter:
      travel_distance = df_play %>% filter(player_id == df_startshot$PLAYER1_ID[i])
      sequence_cor = travel_distance %>% select(x_loc,y_loc) %>% mutate(lead_x=lead(x_loc,1), lead_y=lead(y_loc,1)) %>% 
        mutate(diff_x = x_loc-lead_x, diff_y=y_loc-lead_y) %>% mutate(distance=sqrt(diff_x**2+diff_y**2))
      distance = sum(sequence_cor$distance,na.rm = TRUE)
      df_startshot$travel_distance[i] <- distance
      ###########################################################################################################
    }
    # # Calculate the speed of the shooter
    # cal_speed <- sum(all.movements %>%
    #                    filter(quarter == df_startshot$quarter[i] &
    #                             game_clock >= df_startshot$game_clock[i] & game_clock <= (df_startshot$game_clock[i]+2)) %>% 
    #                    distinct(player_id, quarter, game_clock, .keep_all = TRUE) %>% 
    #                    filter(player_id == df_startshot$PLAYER1_ID[i]) %>% mutate(lead_x=lead(x_loc,1), lead_y=lead(y_loc,1)) %>% 
    #                    mutate(diff_x = x_loc-lead_x, diff_y=y_loc-lead_y) %>% mutate(distance=sqrt(diff_x**2+diff_y**2)) %>% select(distance),na.rm = TRUE)/2
    # df_startshot$travel_speed[i] <- cal_speed
    ###########################################################################################################
    # Calculate the speed of the shooter
    player_this_moment = all.movements %>%
      filter(quarter == df_startshot$quarter[i] &
               game_clock >= df_startshot$game_clock[i] & game_clock <= (df_startshot$game_clock[i]+2)) %>% 
      distinct(player_id, quarter, game_clock, .keep_all = TRUE)
    if((df_startshot$PLAYER1_ID[i] %in% player_this_moment$player_id)){
      cal_speed <- sum(player_this_moment %>% filter(player_id == df_startshot$PLAYER1_ID[i]) %>% mutate(lead_x=lead(x_loc,1), lead_y=lead(y_loc,1)) %>% 
                         mutate(diff_x = x_loc-lead_x, diff_y=y_loc-lead_y) %>% mutate(distance=sqrt(diff_x**2+diff_y**2)) %>% select(distance),na.rm = TRUE)/2
      df_startshot$travel_speed[i] <- cal_speed
    }
  }
  
  
  
  
  t = 35
  # assuming in chronogical order
  unique_shots_id = unique(sumtotal3$shot_id)
  df_leave_first40 = data.frame()
  
  for (i in unique_shots_id){
    trans = sumtotal3 %>% filter(shot_id==i)
    index = which(trans$threedist>22)[1] #first index where distance > 22
    trans = trans[index:(index+t),]
    df_leave_first40 = rbind(df_leave_first40,trans)
  }
  
  store_coords = matrix(NA, nrow = length(unique_shots_id), ncol = t * 3)
  for (i in 1:length(unique_shots_id)) {
    coords = ramify::flatten(as.matrix(df_leave_first40 %>% filter(shot_id == unique_shots_id[i]) %>% select(x_loc,y_loc,radius)), across = "rows")
    store_coords[i, ] = coords[1:(t * 3)]
  }
  Final_df = as.data.frame(store_coords)
  cols = NULL
  for (i in 1:(dim(Final_df)[2]/3)){
    for (j in c('X','Y','Z')){
      col = paste0(j, i)
      cols <- c(cols, col)
    }
  }
  colnames(Final_df) = cols
  df_startshot = df_startshot[order(match(df_startshot$shot_id,unique_shots_id)),]
  Final_df = Final_df %>% mutate(court_zone = df_startshot$court_zone, position =  df_startshot$position,
                      travel_distance = df_startshot$travel_distance,travel_speed = df_startshot$travel_speed, 
                      num_team = df_startshot$num_team, num_defen = df_startshot$num_defen, Result = df_startshot$EVENTMSGTYPE)
  
  
  
  write.csv(Final_df, paste0("data/trajectory/", as.character(gameid), ".csv"), row.names = FALSE)

  # n = n + 1
  toc()
  cat(paste0(filename, '| processing finished! Starting for next one.'))
}



# threes = plyr::rbind.fill(storage)
# 
# final <- threes %>%
#   arrange(gameid, playid, desc(game_clock)) #%>%
# # select(-X, --a_score, -h_score) %>%
# # arrange(gameid, playid, desc(game_clock))
# 
# write.csv(final, "GitHub/3PT-Shot-Prediction/test.csv", row.names = FALSE)
# 
# ##Validate findings
# test <- final %>% group_by(gameid, playid) %>% summarize(count = n())
# summary(test$count)
# 
# ##Get specific plays
# testplay <- final %>% filter(gameid == '0021500418' & playid == '15')
# testplay <- final %>% filter(playid == '21')
# testplayball <- testplay %>% filter(player_id == '-1')
