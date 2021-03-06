close all
clear all
RNG_SEED = rng;

%% Load the proper dataset
%The following line loads X_all, Y_all, and keywords (name of features)
load('DATA_amazon\amazon_data');
%The following line loads sparse parameters learned by CV and also theta_star 
% and P_gamma leaned by using all the data (ground truth).
load('DATA_amazon\cv_results');

%% load user feedback from the user experiments
load('DATA_amazon\User Study\z_star_user_exp');
num_users = size(z_star_user_exp,1);

%% Parameters and data setup
MODE = 2; 
% MODE specifies the  type of feedback and the model that we are using
%           1: Feedback on weight values. Model: spike and slab prior
%           2: Feedback on relevance of features. Model: spike and slab prior

%data parameters
num_features       = size(X_all,2);
num_data           = size(X_all,1);       %all the data (test, train, user)
num_userdata       = num_data-1000;       %data that will be used to train simulated user
num_trainingdata   = 100;                 %training data

% define z_star_gt in a meaningful way (ground truth of all data)
decision_threshold = 0.7; %this should be on [0.5,1). 
z_star_gt = zeros(num_features,1);
z_star_gt(P_gamma>=decision_threshold) = 1;  %relevant features
z_star_gt(P_gamma<=1-decision_threshold) = 0; %non-relevant features 
z_star_gt(P_gamma<decision_threshold & P_gamma>1-decision_threshold) = -1; %"don't know" features 

%simulation parameters
num_iterations   = 200 +1; %total number of user feedback
num_runs         = 20;   %total number of runs (necessary for averaging results)

%model parameters 
sparse_options = struct('damp',0.8, 'damp_decay',0.95, 'robust_updates',2, 'verbosity',0, ...
    'max_iter',1000, 'threshold',1e-5, 'min_site_prec',1e-6);
sparse_params  = struct('sigma2',1, 'tau2', 0.1^2 ,'p_u', decision_threshold,'rho', 0.3, 'simulated_data', 0 ); 
sparse_params.eta2 = 0.1^2;   % (NOT USED IN MODE=2)  
%% Let the algortihm learns the parameters 
%(comment the folloing lines if you want to use the CV results)
sparse_params.sigma2_prior = true;
sparse_params.sigma2_a  = 1;
sparse_params.sigma2_b  = 1;
sparse_params.rho_prior = false;
% % sparse_params.rho_a = 1;
% % sparse_params.rho_b = 1;
%% METHOD LIST
% Set the desirable methods to 'True' and others to 'False'. only the 'True' methods will be considered in the simulation
METHODS_ED = {     
     'True',  'Random';
     'False',  'First relevant features, then non-relevant';
     'False',  'Max posterior inclusion probability';
     'False', 'max variance';
     'False',  'Expected information gain, full EP approx';
     'False',  'Expected information gain, full EP approx, non-sequential';
     'True',  'Expected information gain, fast approx'; %fast approx methdos are available for MODE = 2 only
     'False',  'Expected information gain, fast approx, non-sequential' %fast approx methdos are available for MODE = 2 only
     };
METHODS_AL = {
     'False',  'AL:Uniformly random';
     'False',  'AL: Expected information gain'
     }; 
METHODS_GT = {
     'False',  'Ground truth - all data';
     'True',  'Ground truth - all feedback'
     }; 
Method_list_ED = [];
for m = 1:size(METHODS_ED,1)
    if strcmp(METHODS_ED(m,1),'True')
        Method_list_ED = [Method_list_ED,METHODS_ED(m,2)];
    end
end
Method_list_AL = [];
for m = 1:size(METHODS_AL,1)
    if strcmp(METHODS_AL(m,1),'True')
        Method_list_AL = [Method_list_AL,METHODS_AL(m,2)];
    end
end
Method_list_GT = [];
for m = 1:size(METHODS_GT,1)
    if strcmp(METHODS_GT(m,1),'True')
        Method_list_GT = [Method_list_GT,METHODS_GT(m,2)];
    end
end
Method_list = [Method_list_GT, Method_list_ED, Method_list_AL];
num_methods = size(Method_list,2); %number of decision making methods that we want to consider
%% Main algorithm
Loss_1 = zeros(num_methods, num_iterations, num_runs, num_users);
Loss_2 = zeros(num_methods, num_iterations, num_runs, num_users);
decisions = zeros(num_methods, num_iterations, num_runs, num_users); 
tic
for run = 1:num_runs
    disp(['run number ', num2str(run), ' from ', num2str(num_runs), '. acc time = ', num2str(toc) ]);
    % randomly divide the data into training, test, and user data.
    [X_train, X_user, X_test, Y_train, Y_user, Y_test] = partition_data(X_all, Y_all, num_userdata, num_trainingdata);
    %% normalize the data 
    %We normalise training and user data together (the methods can see them, well, at least the Xs)
    x_mean  = mean([X_user,X_train],2);
    x_std   = std([X_user,X_train]')'; 
    %some of the x_stds can be zero if training size is small. don't divide the data by std if std==0    
    x_std(x_std==0) = 1;
    X_train = bsxfun(@minus,X_train,x_mean);
    X_train = bsxfun(@rdivide, X_train, x_std);
    X_test  = bsxfun(@minus,X_test,x_mean);
    X_test  = bsxfun(@rdivide, X_test, x_std);  
    X_user = bsxfun(@minus,X_user,x_mean);
    X_user = bsxfun(@rdivide, X_user, x_std);
    
    %Find constant features. Due to some numerical issues after the normalization, we need to consider an epsilon distance
    non_const_features = (std(X_train')>0.00001 | std(X_train')<-0.00001);  
    
    y_mean  = mean([Y_user;Y_train]);
    y_std   = std([Y_user;Y_train]); 
    Y_user = (Y_user - y_mean)./y_std;
    Y_train = (Y_train - y_mean)./y_std;    
    %% learn user feedback and model by using "user" data 
    %train with the user data to learn the parameters (calculate posterior without feedback)
    sparse_options.si = [];
    posterior = calculate_posterior(X_user, Y_user, [], 2, sparse_params, sparse_options);
    theta_star_user = posterior.mean;
    for user = 1:num_users
        z_star_user = z_star_user_exp(user,:);

        %% main algorithms (ED, AL, and GT)
        for method_num = 1:num_methods
            method_name = Method_list(method_num);
            %% restart the variables
            x_train = X_train;
            x_test  = X_test;
            y_train = Y_train;
            theta_star_user_temp = theta_star_user;
            z_star_user_temp = z_star_user;
            z_star_gt_temp = z_star_gt;
            %for AL methods and for ED when MODE ~= 0,1, remove all const features
            if MODE == 2 || ~isempty(find(strcmp(Method_list_AL, method_name), 1))
                %remove the all constant features from the training and test data
                x_train = X_train(non_const_features,:);
                x_test  = X_test(non_const_features,:);
                x_user  = X_user(non_const_features,:);
            end
            %if feedback is on relevance of features then remove constant features (no added information)
            if MODE == 2
                theta_star_user_temp = theta_star_user(non_const_features);
                z_star_user_temp = z_star_user(non_const_features);
                z_star_gt_temp = z_star_gt(non_const_features);
            end   
            %Feedback = values (1st column) and indices (2nd column) of user feedback
            Feedback = [];            %only used in experimental design methdos
            %selected_data = indices of data selected by active learning from X_user and Y_user
            selected_data = [];       %only used in active learning methods
            sparse_options.si = [];   % carry prior site terms between interactions
            %% Calculate ground truth solutions
            if find(strcmp(Method_list_GT, method_name))
                if find(strcmp('Ground truth - all data', method_name))
                    %calculate the posterior based on all train+user data 
                    posterior = calculate_posterior([X_train, X_user], [Y_train; Y_user], Feedback, ...
                        MODE, sparse_params, sparse_options);
                end
                if find(strcmp('Ground truth - all feedback', method_name))
                    %calculate the posterior based on all feedbacks
                    for feature_index = 1:size(X_train,1)
                        new_fb_value = user_feedback(feature_index, theta_star_user, z_star_user, MODE, sparse_params);
                        Feedback = [Feedback; new_fb_value , feature_index];
                    end
                     posterior = calculate_posterior(X_train, Y_train, Feedback, ...
                        MODE, sparse_params, sparse_options);                                            
                end
                Y_hat = X_test'*posterior.mean;
                Y_hat = Y_hat .* y_std + y_mean;
                Y_hat_train = X_train'*posterior.mean;
                Loss_1(method_num, :, run, user) = mean((Y_hat- Y_test).^2); %MSE
                Loss_2(method_num, :, run, user) = mean((Y_hat_train- Y_train).^2); %MSE on training in the normalized space
                continue
            end
            %% for non-sequential ED methods find the suggested queries before user interaction
            if strfind(char(method_name),'non-sequential')
                posterior = calculate_posterior(x_train, y_train, [], MODE, sparse_params, sparse_options);
                %find non-sequential order of features to be queried from the user
                non_seq_feature_indices = decision_policy(posterior, method_name, z_star_gt_temp, x_train, y_train, ...
                    [], MODE, sparse_params, sparse_options);
            end
            %% User interaction
            for it = 1:num_iterations %number of user feedback
                %calculate the posterior based on training + feedback until now
                posterior = calculate_posterior(x_train, y_train, Feedback, MODE, sparse_params, sparse_options);
                sparse_options.si = posterior.si;
                %% calculate different loss functions
                % transform predictions back to the original scale
                Y_hat = x_test'*posterior.mean;
                Y_hat = Y_hat .* y_std + y_mean;     
                Y_hat_train = x_train'*posterior.mean;                
                Loss_1(method_num, it, run, user) = mean((Y_hat- Y_test).^2); %MSE
                Loss_2(method_num, it, run, user) = mean((Y_hat_train- y_train).^2); %MSE on training in the normalized space
                %% If ED: make a decision based on ED decision policy
                if find(strcmp(Method_list_ED, method_name))
                    %for non-sequential methods, use the saved order
                    if strfind(char(method_name),'non-sequential')
                        feature_index = non_seq_feature_indices(it);
                    else
                        %for sequential methods find the next decision based on feedback until now
                        feature_index = decision_policy(posterior, method_name, z_star_gt_temp, x_train, y_train,...
                            Feedback, MODE, sparse_params, sparse_options);
                    end             
                    if MODE == 2
                        %save the true feature index (consider the removed features too)
                        decisions(method_num, it, run, user) = find(cumsum(non_const_features)==feature_index,1);
                    else
                        decisions(method_num, it, run, user) = feature_index;
                    end
                    %simulate user feedback
                    new_fb_value = user_feedback(feature_index, theta_star_user_temp, z_star_user_temp, MODE, sparse_params);
                    Feedback = [Feedback; new_fb_value , feature_index];
                end
                %% If AL: add a new data point based on AL decision policy 
                if find(strcmp(Method_list_AL, method_name))               
                    [new_selected_data] = decision_policy_AL(posterior, method_name, x_train, y_train, ...
                        x_user, selected_data, sparse_params, sparse_options);                
                    selected_data = [selected_data;new_selected_data]; 
                    %add active learning selected data to training data
                    x_train = [X_train, X_user(:,selected_data)];
                    y_train = [Y_train; Y_user(selected_data)];
                    %remove constant features in train from test, user, and train(considering the new training data)
                    new_non_const_features = (std(x_train')>0.00001 | std(x_train')<-0.00001);
                    if sum(new_non_const_features) > size(posterior.mean,1)
                        sparse_options.si = [];
                    end
                    %only keep non-constant features
                    x_train = x_train(new_non_const_features,:);
                    x_test  = X_test(new_non_const_features,:);
                    x_user  = X_user(new_non_const_features,:);
                end
            end
        end
    end
end
%% averaging and plotting
z_star = z_star_gt;
save('results_user_exp', 'Loss_1', 'Loss_2', 'decisions', 'sparse_options', 'sparse_params', ...
    'z_star', 'Method_list',  'num_features','num_trainingdata', 'MODE', 'RNG_SEED')
evaluate_results_user_experiments
