
function t_processed = Process_CellCountData2(t_annotated, plate_inkeys, ...
    cond_inkeys, plate_reps, numericfields)
% t_processed = Process_CellCountData(t_annotated, plate_inkeys, cond_inkeys,
%                               plate_reps, numericfields)
%
%   process the data from cell count. The data will be split for controls according
%   to plate_keys (with 'CellLine' 'TreatmentFile' 'Time' as mandatory and
%   default) and for merging according to cond_keys (with 'Conc' 'DrugName'
%   as default).
%   Needs also the columns 'Untrt' (for Day0 or control plate), 'pert_type' (looking for value
%   'ctl_vehicle' or 'trt_cp'/'trt_poscon') and 'DesignNumber' (serves as
%   replicates/ plate number)
%   Set 'plate_reps' as true if there are replicates on the same plates
%   (this will bypass the check in creating t_mean).
%
%   outputs are:    t_processed with the values for all treated wells
%
fprintf('Process the cell count data, normalize by controls:\n');

%% assign and control the variables
if exist('plate_inkeys','var') && ~isempty(plate_inkeys)
    plate_keys = unique([{'Barcode' 'CellLine' 'Time'} plate_inkeys]);
else
    plate_keys = {'Barcode' 'CellLine' 'Time'};
    plate_inkeys = {};
end
if exist('cond_inkeys','var') && ~isempty(cond_inkeys)
    cond_keys = unique([{'DrugName' 'Conc'} cond_inkeys]);
else
    cond_keys = {'DrugName' 'Conc'};
end
if ~exist('plate_reps','var') || isempty(plate_reps)
    plate_reps = false;
end

cond_keys = [cond_keys ...
    intersect(varnames(t_annotated), strcat('DrugName', cellfun(@(x) {num2str(x)}, num2cell(2:9)))) ...
    intersect(varnames(t_annotated), strcat('Conc', cellfun(@(x) {num2str(x)}, num2cell(2:9))))];

assert(all(ismember([plate_keys cond_keys 'pert_type'], t_annotated.Properties.VariableNames)),...
    'Column(s) [ %s ] missing from t_data', strjoin(setdiff([plate_keys cond_keys 'pert_type'], ...
    unique(t_annotated.Properties.VariableNames)),' '))

% decide if growth inhibition can be calculated (need untreated & time=0 OR timecourse)
EvaluateGR = any(t_annotated.pert_type=='Untrt') || ...
    any(t_annotated.pert_type=='ctl_vehicle' & t_annotated.Time==0) || ...
    length(unique(t_annotated.Time(t_annotated.pert_type=='ctl_vehicle')))>=4; % case for extrapolation
% decide if evaluating death count
EvaluateDead = isvariable(t_annotated,'Deadcount');

labelfields = {'pert_type' 'RelCellCnt' 'RelGrowth' 'GRvalue' 'DesignNumber' 'Barcode' ...
    'Untrt' 'Cellcount' 'Date' 'Row' 'Column' 'Well' 'TreatmentFile' 'Replicate'};
if ~exist('numericfields','var')
    numericfields = setdiff(t_annotated.Properties.VariableNames( ...
        all(cellfun(@isnumeric, table2cell(t_annotated(1:min(40,end),:))))), ...
        [plate_keys cond_keys labelfields]);
    if ~isempty(numericfields)
        fprintf('\tThese numeric fields will be averaged (set as cond_inkeys to use them as key):\n');
        for i=1:length(numericfields)
            fprintf('\t - %s\n', numericfields{i});
        end
    end
end
%%

% find the number of different of plates to merge and group them based on
% the plate_keys (with Time==0)
t_plate = unique(t_annotated(:,plate_keys));
t_plate = t_plate(t_plate.Time~=0,:);

t_processed = table;
t_mean = table;
DisplayTC = false;
t_toofew = table();
t_toomany = table();
% loop through the different plates
for iP = 1:height(t_plate)
    %
    % find the cell count at day 0
    if EvaluateGR
        temp = t_plate(iP,setdiff(plate_keys, {'TreatmentFile' 'Barcode'}, 'stable'));
        temp.Time = 0;
        idx = eqtable(temp, t_annotated);
        if any(idx)
            Day0Cnt = trimmean(t_annotated.Cellcount(idx), 50);
            if EvaluateDead
                Day0DeadCnt = trimmean(t_annotated.Deadcount(idx), 50);
            end
        else
            if ~DisplayTC
                disp('Extrapolating Day0 from time course')
                DisplayTC = true;
            end
            temp = t_plate(iP,setdiff(plate_keys, {'TreatmentFile' 'Time'}, 'stable'));
            subt = t_annotated(eqtable(temp, t_annotated) & ...
                t_annotated.pert_type=='ctl_vehicle', ...
                {'Cellcount' 'Time'});
            subt = sortrows(collapse(subt(subt.Time>0,:), @(x) trimmean(x,50), 'keyvars', 'Time'), 'Time');
            if height(subt)<4
                warnprintf('Expecting a time course, but less than 5 time points --> no Day0')
                EvaluateGR = false;
                Day0Cnt = NaN;
                Day0DeadCnt = NaN;
            else
                cnt_t0 = exp(log(subt.Cellcount(1)) - subt.Time(1)*...
                    (log(subt.Cellcount)-log(subt.Cellcount(1)))./(subt.Time-subt.Time(1)));
                Day0Cnt = mean(cnt_t0([2 3 3 4]));
                
                if EvaluateDead
                    Dcnt_t0 = exp(log(subt.Deadcount(1)) - subt.Time(1)*...
                        (log(subt.Deadcount)-log(subt.Deadcount(1)))./(subt.Time-subt.Time(1)));
                    Day0DeadCnt = mean(Dcnt_t0([2 3 3 4]));
                    
                    
                end
            end
        end
    else
        Day0Cnt = NaN;
    end
    
    Relvars = {'RelCellCnt' 'GRvalue'};
    t_conditions = t_annotated(eqtable(t_plate(iP,:), t_annotated(:,plate_keys)) , :);
    
    % found the control for treated plates (ctl_vehicle)
    t_ctrl = t_conditions(t_conditions.pert_type=='ctl_vehicle',:);
    assert(height(t_ctrl)>0, 'No control found for %s --> check ''pert_type''', ...
        strjoin(strcat(table2cellstr( t_plate(iP,:), 0)), '|'))
    
    t_ctrl = collapse(t_ctrl, @(x) trimmean(x,50), ...
        'keyvars', plate_keys, ...
        'valvars', [{'Cellcount'} numericfields]);
    t_ctrl.Properties.VariableNames{'Cellcount'} = 'Ctrlcount';
    for i=1:length(numericfields)
        t_ctrl.Properties.VariableNames{numericfields{i}} = ['Ctrl_' numericfields{i}];
    end
    t_ctrl = [t_ctrl table(repmat(Day0Cnt, height(t_ctrl),1), 'VariableNames', {'Day0Cnt'})];
    
    if EvaluateGR && EvaluateDead
        t_ctrl = [t_ctrl table(repmat(Day0DeadCnt, height(t_ctrl),1), ...
            'VariableNames', {'Day0DeadCnt'})];
    end
    
    % report the ctrl values in the table
    t_conditions = innerjoin(t_conditions, t_ctrl);
    % evaluate the relative cell count/growth
    t_conditions = [t_conditions array2table([t_conditions.Cellcount./t_conditions.Ctrlcount ...
        2.^(log2(t_conditions.Cellcount./t_conditions.Day0Cnt)./log2(t_conditions.Ctrlcount./t_conditions.Day0Cnt))-1], ...
        'variablenames', Relvars)];
    
    if EvaluateGR && EvaluateDead
        
        t_c = t_conditions;
        %%%% capping of extreme values
        % if missing cells -> assign to dead cells
        cond_idx = (t_c.Deadcount+t_c.Cellcount) < ...
            .95*(t_c.Day0Cnt + t_c.Day0DeadCnt);
        if any(cond_idx)
            %             warnprintf('%i conditions with too few cells -> assigned as dead cells', sum(cond_idx))
            t_toofew = [t_toofew
                t_c(cond_idx,{'CellLine' 'DrugName'})];
            
            t_c.Deadcount(cond_idx) = max( t_c.Deadcount(cond_idx) , ...
                (t_c.Day0Cnt(cond_idx) + t_c.Day0DeadCnt(cond_idx)) - ...
                floor(.95*t_c.Cellcount(cond_idx)) +1);
        end
        
        % if too many dead cells -> subtract dead cells
        cond_idx = t_c.pert_type~='ctl_vehicle' & (t_c.Deadcount+t_c.Cellcount > ...
            1.15*(t_c.Ctrlcount + t_c.Ctrl_Deadcount));
        if any(cond_idx)
            %             warnprintf('%i conditions with too many cells -> remove dead cells', sum(cond_idx))
            t_toomany = [t_toomany
                t_c(cond_idx,{'CellLine' 'DrugName'})];
            
            t_c.Deadcount(cond_idx) = min( t_c.Deadcount(cond_idx) , ...
                (t_c.Ctrlcount(cond_idx) + t_c.Ctrl_Deadcount(cond_idx)) - ...
                ceil(1.15*t_c.Cellcount(cond_idx)) -1);
        end
        
        Time = t_c.Time;
        if any(Time>14)
            % time in hours -> transform in days
            %             warnprintf('Time transformed in days for normalization of GR_d')
            Time = Time/24;
        end
        
        Dratio = max(t_c.Deadcount - t_c.Day0DeadCnt,1)./...
            (t_c.Cellcount - t_c.Day0Cnt);
        Dratio_ctrl = max(t_c.Ctrl_Deadcount - t_c.Day0DeadCnt,1)./...
            (t_c.Ctrlcount - t_c.Day0Cnt);
        gr = log2(t_c.Cellcount./t_c.Day0Cnt);
        gr_ctrl = log2(t_c.Ctrlcount./t_c.Day0Cnt);
        
        GR_s = 2.^((1+Dratio).*gr./((1+Dratio_ctrl).*gr_ctrl))-1;
        GR_d = 2.^( ( (Dratio_ctrl).*gr_ctrl - (Dratio).*gr )./Time )-1;
        
        Eqidx = (abs(t_c.Cellcount - t_c.Day0Cnt)./t_c.Cellcount)<1e-10;
        if any(Eqidx)
            warnprintf('Some conditions with t_c.Cellcount ~= t_c.Day0Cnt -> finite evaluation')
            % issue when t_c.Cellcount == t_c.Day0Cnt -> Taylor series
            disp(t_c(Eqidx,:))
            a = t_c.Cellcount(Eqidx);
            b = t_c.Day0Cnt(Eqidx);
            
            Dratio_gr = max(t_c.Deadcount(Eqidx) - t_c.Day0DeadCnt(Eqidx),1)* ...
                (1./b + diag(( repmat((-1)*(a-b),1,35).^repmat(1:35,length(a),1) ) * ...
                (repmat(b,1,35).*repmat(1:35,length(b),1))')  );
            
            GR_s(Eqidx) = 2.^((gr(Eqidx)+Dratio_gr)./((1+Dratio_ctrl(Eqidx)).*gr_ctrl(Eqidx)))-1;
            GR_d(Eqidx) = 2.^( ( (Dratio_ctrl(Eqidx)).*gr_ctrl(Eqidx) - Dratio_gr )./Time )-1;
        end
        
        t_conditions = [t_conditions array2table([ GR_s  GR_d ], ...
            'variablenames', {'GR_s' 'GR_d'})];
    end
    
    if ~EvaluateGR
        t_conditions.GRvalue = [];
        t_conditions.Day0Cnt = [];
        Relvars = {'RelCellCnt'};
    end
    
    t_processed = [t_processed; t_conditions];
    
end
if height(t_toofew)>10
    warnprintf('%i conditions with too few cells -> assigned as dead cells', height(t_toofew))
    t_ = group_counts(t_toofew);
    disp(sortrows(t_(t_.counts>5,:),3))
end
if height(t_toomany)>10
    warnprintf('%i conditions with too many cells -> remove dead cells', height(t_toomany))
    t_ = group_counts(t_toomany);
    disp(sortrows(t_(t_.counts>5,:),3))
end