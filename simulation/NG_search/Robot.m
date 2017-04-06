classdef Robot
    properties
        % motion specs
        traj;
        state; % [x;y;theta;v]
        a_lb;
        a_ub;
        w_lb;
        w_ub;
        v_lb;
        v_ub;
        
        % sensor specs
        sensor_type; 
        theta0; % sensor range in angle
        r; % sensor range
        % linear sensor
        C; % C matrix of observation
        % nonlinear sensor
        h; % y=h(x)
        del_h; % gradient of h
        R; % covariance for sensor model
        
        % observation
        y; % observation measurement
        
        % filtering
        % xKF
        est_pos; % estimated target position
        P; % estimation covariance
        est_pos_hist;
        P_hist;
        % GMM
        gmm_num; % # of gmm components
        max_gmm_num; % max # of gmm components for gmm fitting purpose
        wt; % weigths of gmm components
        % PF
        particles; % array of particle positions [x;y]
        gmm_mu; % array of mean [x;y]
        gmm_sigma; % cell of covariance
        
        % path planning
        mpc_hor;
        dt;
        optu;
        gam; % coefficient for sigmoid function
        
        % performance metrics
        ml_pos;
        ent_pos;
    end
    
    methods
        function this = Robot(inPara)
            this.state = inPara.state;
            this.traj = inPara.state;
            this.a_lb = inPara.a_lb;
            this.a_ub = inPara.a_ub;
            this.w_lb = inPara.w_lb;
            this.w_ub = inPara.w_ub;
            this.v_lb = inPara.v_lb;
            this.v_ub = inPara.v_ub;
            this.R = inPara.R;
            this.h = inPara.h;
            this.del_h = inPara.del_h;
            this.theta0 = inPara.theta0;
            this.r = inPara.range;
            
            % filtering
            this.sensor_type = inPara.sensor_type;
            % xKF
            this.est_pos = inPara.est_pos;
            this.P = inPara.P;
            this.est_pos_hist = [];
            this.P_hist = [];        
            % gmm
            this.gmm_num = inPara.gmm_num;
            this.wt = inPara.wt;
            % pf
            this.max_gmm_num = inPara.max_gmm_num;
            this.particles = inPara.particles;
            
            this.mpc_hor = inPara.mpc_hor;
            this.dt = inPara.dt;
            this.optu = [];
            this.gam = inPara.gam;
        end
        
        %% sensor modeling
        % approximate straightline edge of sensor FOV based on current
        % robot state
        function [a,b] = FOV(this,st)
            theta = st(3);
            x0 = st(1);
            y0 = st(2);
            alp1 = theta - this.theta0;
            alp2 = theta + this.theta0;
            a = [sin(alp1),-cos(alp1);-sin(alp2),cos(alp2)]; % [a1;a2]
            b = [x0*sin(alp1)-y0*cos(alp1);-x0*sin(alp2)+y0*cos(alp2)];%[b1;b2];
        end
        
        % determine if the target is in sensor FOV
        function flag = inFOV(this,tar_pos)
            [a,b] = this.FOV(this.state);
            flag = (a(1,:)*tar_pos-b(1) <= 0) && (a(2,:)*tar_pos-b(2) <= 0)...
                && (norm(tar_pos-this.state(1:2)) <= this.r);
%             flag = (norm(tar_pos-this.state(1:2)) <= this.r);
        end
        
        %% measurement generation
        % generate a random measurement
        function y = sensorGen(this,fld)
            tar_pos = fld.target.pos;
            % range-bearing sensor
            if strcmp(this.sensor_type,'rb')
                if this.inFOV(tar_pos)
                    y = this.h(tar_pos,this.state(1:2))+(mvnrnd([0;0],this.R))';
                else
                    y = [-100;-100];
                end
            elseif strcmp(this.sensor_type,'ran')
                if this.inFOV(tar_pos)
                    y = norm(tar_pos-this.state(1:2))+normrnd(0,this.R);
                else
                    y = -100;
                end
            end
        end
        
        %% filtering
        function this = KF(this,fld)
            y = this.y;
            
            % target
            tar = fld.target;
            A = tar.A;
            B = tar.B;
            Q = tar.Q;
            
            % current estimation
            x = this.est_pos;
            P = this.P;
            
            % sensor
            C = this.C;
            R = this.R;
            
            % prediction
            x_pred = A*x+B;
            P_pred = A*P*A'+Q;
            
            % update
            if sum(y-[-100;-100]) ~= 0
                % if an observation is obtained
                K = P_pred*C'/(C*P_pred*C'+R);
                x_next = x_pred+K*(y-C*x_pred);
                P_next = P_pred-K*C*P_pred;
            else
                x_next = x_pred;
                P_next = P_pred;
            end
            
            this.est_pos = x_next;
            this.P = P_next;
            this.est_pos_hist = [this.est_pos_hist,x_next];
            this.P_hist = [this.P_hist,P_next];
        end
        
        function this = GSF(this,fld)                                                
            % target
            tar = fld.target;
            f = tar.f;
            del_f = tar.del_f;
            Q = tar.Q;
            
            % sensor
            h = this.h;
            del_h = this.del_h;
            R = this.R;            
            % measurement
            y = this.y;
            
            % used for updating gmm component weights
            alp = ones(this.gmm_num,1); 
            
            for ii = 1:this.gmm_num 
                % current estimation
                P = this.P{ii};
                x = this.est_pos(:,ii);
                A = del_f(x);
                % prediction
                x_pred = f(x); %%% replace this one with new nonlinear model                                
                P_pred = A*P*A'+Q;
                
                % update
                % sensor model linearization
                C = del_h(x_pred);
                                                
                if sum(y-[-100;-100]) ~= 0
                    % if an observation is obtained
                    K = P_pred*C'/(C*P_pred*C'+R);
                    x_next = x_pred+K*(y-h(x_pred));
                    P_next = P_pred-K*C*P_pred;
                    alp(ii) = mvnpdf(y,h(x_pred),C*P_pred*C'+R);
                else
                    x_next = x_pred;
                    P_next = P_pred;
                end
                
                this.est_pos(:,ii) = x_next;
                this.P{ii} = P_next;
            end
            
            % update gmm component weight
            wt = this.wt.*alp;
            this.wt = wt/sum(wt);
            tar_mean = this.est_pos*this.wt;
            tar_cov = zeros(2,2);
            for jj = 1:this.gmm_num
                tar_cov = tar_cov+this.wt(jj)*this.P{jj};
            end
            this.est_pos_hist = [this.est_pos_hist,tar_mean];
            this.P_hist = [this.P_hist,tar_cov];
        end
        
        function this = PF(this,fld)
            % particle filter           
            
            % target
            tar = fld.target;     
            f = tar.f;
            % sensor
            h = this.h;
            % measurement
            y = this.y;
            
            particles = this.particles;
            
            %% particle filtering
            np = size(particles,2); % number of particles
            
            % initalize particles weights
            w = zeros(np,1);
            
            % state update: since we use the static target, no update is needed
            pred_par = zeros(2,np); % predicted particle state
            for ii = 1:np
               pred_par(:,ii) = f(particles(:,ii));
            end
            
            % weight update            
            for ii = 1:np
                if sum(y == -100) >= 1 
                    % if the target is outside FOV.
                    if this.inFOV(pred_par(:,ii))
                        w(ii) = 0.01;
                    else
                        w(ii) = 0.99;
                    end
                else
                    if this.inFOV(pred_par(:,ii))
                        w(ii) = mvnpdf(y,this.h(pred_par(:,ii),this.state(1:2)),this.R);
                    else
                        w(ii) = 0.01;
                    end
                end
            end
            w = w/sum(w);
            
            % resampling
            idx = randsample(1:np, np, true, w);
            new_particles = particles(:,idx);
            this.particles = new_particles;
            
            %%%%% may need to deal with practical issues in PF, to be
            %%%%% filled later
            
            %% gmm fitting
            max_gmm_num = this.max_gmm_num; % maximum gmm component number
                        
            gmm_model = cell(max_gmm_num,1);
            opt = statset('MaxIter',1000);
            AIC = zeros(max_gmm_num,1);
            tic;
            for kk = 1:max_gmm_num
                gmm_model{kk} = fitgmdist(new_particles',kk,'Options',opt,...
                    'Regularize',0.001,'CovType','full');
                AIC(kk)= gmm_model{kk}.AIC;
            end
            display ('gmm fitting takes time as:');
            toc;
            
            [minAIC,numComponents] = min(AIC);
            
            best_model = gmm_model{numComponents};
            this.gmm_num = numComponents;
            this.gmm_mu = best_model.mu';           
            this.gmm_sigma = best_model.Sigma;
            this.wt = best_model.PComponents';
            
            % convert the data form to be compatible with the main code
            this.est_pos = this.gmm_mu(:);
            for ii = 1:numComponents                
                this.P{ii} = this.gmm_sigma(:,:,ii);
            end
        end
        
        %% planning
        
        function [optz,optu] = cvxPlanner(this,fld,init_sol)            
            % use the multi-layer approach similar to Sachin's work. Fix
            % the parameter for the sensor, solve path planning. Then
            % refine the parameter until close to reality. In each
            % iteration, a convex program is solved. The initial solution
            % comes from ngPlanner
            
            % planing in non-Gaussian (GMM) belief space
            N = this.mpc_hor;
            dt = this.dt;
            
            % target 
            tar = fld.target;
            f = tar.f;
            del_f = tar.del_f;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            
            Q = tar.Q;
            
            % sensor
            h = this.h;    
            del_h = this.del_h;
            R = this.R; 
            
            % the parameter for the sensing boundary approximation
            alp = 1;
            alp_inc = 2; % increament paramter for alpha
            
            % set up simulation
            % robot state and control
            z = sdpvar(4,N+1,'full'); % robot state
            u = sdpvar(2,N,'full'); % robot control
            % estimation
            x = sdpvar(2*this.gmm_num,N+1,'full'); % target mean
            P = sdpvar(2*this.gmm_num,2*(N+1),'full'); % a set of 2-by-2 symmetric matrices
            
            % auxiliary variable
            %             tmp_M = sdpvar(2,2,'full');
%             K = sdpvar(2*this.gmm_num,2*N,'full');
            %             phi = sdpvar(2,2,'full');
            %             tmp1 = sdpvar(2,N,'full');
            t = sdpvar(this.gmm_num*this.gmm_num,N+1); % dummy variable for LMI
            slack = sdpvar(1);
            
            % debug purpose
            x_pred = sdpvar(2*this.gmm_num,N,'full');
            P_pred = sdpvar(2*this.gmm_num,2*N,'full');                       
            
            zref = init_sol.zref;
            uref = init_sol.uref;
            xref = init_sol.xref;
            Kref = init_sol.Kref;
            while (1)
                
                % obj
                obj = sum(sum(t))+slack;

                % constraints
                % epigraph for obj
                constr = [t>=0,slack>=0];
                for ii = 1:N
                    for jj = 1:this.gmm_num
                        tmp = 0;
                        for ll = 1:this.gmm_num
                            % LMI
                            constr = [constr,[P(2*ll-1:2*ll,2*ii+1:2*(ii+1)) x(2*jj-1:2*jj,ii+1)-x(2*ll-1:2*ll,ii+1);
                                (x(2*jj-1:2*jj,ii+1)-x(2*ll-1:2*ll,ii+1))' t(this.gmm_num*(jj-1)+ll,ii+1)]+slack*eye(3,3)>=0];
                        end                        
                    end
                end
                
                % initial value
                constr = [constr,z(:,1) == this.state];
                constr = [constr,x(:,1) == this.est_pos(:)];
                for jj = 1:this.gmm_num
                    constr = [constr,P(2*jj-1:2*jj,1:2) == this.P{jj}];%[1 0;0 1]];
                end
                
                % constraints on the go
                for ii = 1:N
                    % robot state
                    if isempty(zref)
                        constr = [constr,z(:,ii+1) == z(:,ii)+...
                            [z(4,ii)*cos(z(3,ii));z(4,ii)*sin(z(3,ii));...
                            u(:,ii)]*dt];
                    else
                        % linearize using previous result
                        constr = [constr,z(:,ii+1) == z(:,ii)+...
                            [z(4,ii)*cos(zref(3,ii))-zref(4,ii)*sin(zref(3,ii))*(z(3,ii)-zref(3,ii));
                            z(4,ii)*sin(zref(3,ii))+zref(4,ii)*cos(zref(3,ii))*(z(3,ii)-zref(3,ii));
                            u(:,ii)]*dt];
                    end
                    
                    constr = [constr,[fld.fld_cor(1);fld.fld_cor(3)]<=z(1:2,ii+1)<=...
                        [fld.fld_cor(2);fld.fld_cor(4)]];
                    
                    % use the weighted mean as the MAP of target position                   
                    if isempty(zref)
                        tmp_mean = reshape(x(:,ii+1),2,this.gmm_num)*this.wt;
                        gamma_den = 1; %1+exp(alp*(sum((tmp_mean-z(1:2,ii+1)).^2)-this.r^2));
                        % 1+sum((tmp_mean-z(1:2,ii+1)).^2);
                    else                        
                        tmp_mean = reshape(xref(:,ii+1),2,this.gmm_num)*this.wt;
                        tmp_v = tmp_mean-zref(1:2,ii+1);
                        gamma_den = 1; %%% temporarily set gamma to constant
%                         theta_ref = atan2(tmp_v(2),tmp_v(1)); % angle from the sensor to the target
%                         theta1 = zref(3,ii+1)-this.theta0;
%                         theta2 = zref(3,ii+1)+this.theta0;
%                         a1 = [sin(theta1);-cos(theta1)];
%                         a2 = [-sin(theta2);cos(theta2)];
%                         gamma_den = (1+exp(alp*(sum((tmp_v).^2)-this.r^2)))...
%                             *(1+exp(alp*(tmp_v'*a1)))*...
%                             (1+exp(alp*(tmp_v'*a2)));
%                         gamma_den = 1+(1+sum((tmp_mean-z(1:2,ii+1)).^2))*...
%                             (1+exp(-cos(z(3,ii+1)-theta_ref)+cos(this.theta0)));
                    end
                    gamma_num = 1;
                    
                    % target prediction
                    for jj = 1:this.gmm_num
                        A = del_f(x(2*jj-1:2*jj,ii));
                        if isempty (zref)
                            C = del_h(x(2*jj-1:2*jj,ii),z(1:2,ii));
                        else
                            C = del_h(xref(2*jj-1:2*jj,ii),zref(1:2,ii));
                        end
                        
                        % forward prediction
                        % mean
                        constr = [constr, x_pred(2*jj-1:2*jj,ii) == f(x(2*jj-1:2*jj,ii))];
                        % covariance
                        constr = [constr,P_pred(2*jj-1:2*jj,2*ii-1:2*ii) == A*(P(2*jj-1:2*jj,2*ii-1:2*ii))*A'+Q];
                        
%                         % update K using pesudo measurement
%                         T = C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)*C'+R; % C*P_pred*C'+R
%                         constr = [constr, K(2*jj-1:2*jj,2*ii-1:2*ii)*T == P_pred(2*jj-1:2*jj,2*ii-1:2*ii)*C']; % define K=P_pred*C'(C*P_pred*C'+T)^-1
                        
                        %                     a = T(1,1);
                        %                     b = T(1,2);
                        %                     c = T(2,1);
                        %                     d = T(2,2);
                        %                     t = a*d-b*c;
                        %                     T2 = [d -b; -c a]; % inv(CPC'+R)
                        
                        % since gamma is in factorial form, to avoid division, I
                        % separate the denominator and numerator to two sides of
                        % the equation
                        % mean
                        %%%%% note: for now, I assume the MAP as the target
                        %%%%% position, however, I should change this later
                        %%%%% when using GMM.
                        constr = [constr,x(2*jj-1:2*jj,ii+1) == x_pred(2*jj-1:2*jj,ii)];
                        % covariance
                        if isempty(zref)
                            constr = [constr,(P(2*jj-1:2*jj,2*ii+1:2*ii+2)-P_pred(2*jj-1:2*jj,2*ii-1:2*ii))*gamma_den...
                                == -gamma_num*Kref(2*jj-1:2*jj,2*ii-1:2*ii)*C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)];%+phi];
                        else
                            constr = [constr,(P(2*jj-1:2*jj,2*ii+1:2*ii+2)-P_pred(2*jj-1:2*jj,2*ii-1:2*ii))*gamma_den...
                                == -gamma_num*Kref(2*jj-1:2*jj,2*ii-1:2*ii)*C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)];%+phi];
                        end
                    end
                end
                constr = [constr, this.w_lb <= u(1,:) <= this.w_ub, this.a_lb <= u(2,:) <= this.a_ub...
                    this.v_lb <= z(4,:) <= this.v_ub];
                
                % use the result from last iteration as the initial
                % solution for current iteration
                
                if ~isempty(zref)
                    assign(z,zref)
                    assign(u,uref)
                end
                opt = sdpsettings('solver','mosek','verbose',3,'debug',1,'showprogress',1);
                
                sol1 = optimize(constr,obj,opt);
                zref = value(z);
                uref = value(u);
                
                % terminating condition: the actual in/out FOV is
                % consistent with that of planning
                is_in_fov = zeros(N,1);
                is_in_fov_approx = zeros(N,1);
                xref = value(x);
                tmp_rbt = this;
                %{
                for ii = 1:N
                    tmp_mean = reshape(xref(:,ii+1),2,this.gmm_num)*this.wt;
                    
                    tmp_rbt.state = zref(:,ii+1);
                    is_in_fov(ii) = tmp_rbt.inFOV(tmp_mean);
                    
                    tmp_v = tmp_mean-zref(1:2,ii+1);
                    theta_ref = atan2(tmp_v(2),tmp_v(1));
                    theta1 = zref(3,ii+1)-this.theta0;
                    theta2 = zref(3,ii+1)+this.theta0;
                    a1 = [sin(theta1);-cos(theta1)];
                    a2 = [-sin(theta2);cos(theta2)];
                    is_in_fov_approx(ii) = 1/((1+exp(alp*(sum((tmp_v).^2)-this.r^2)))...
                        *(1+exp(alp*(tmp_v'*a1)))*...
                        (1+exp(alp*(tmp_v'*a2))));
                    %(1+exp(-cos(zref(3,ii+1)-theta_ref)+cos(this.theta0))));
                end
                
                dif = norm(is_in_fov-is_in_fov_approx,1);
                if dif < 0.1*N
                    break
                end
                %}
                break
                
                alp = alp*alp_inc;
            end
            
            optz = zref;
            optu = uref;
            %}
        end
        
        %%% can delete this cvxPlanner2 if the above cvxPlanner works. In
        %%% fact, the yalmip syntax makes it hard to put matrix into sdp
        %%% format
        function [optz,optu] = cvxPlanner2(this,fld,init_sol)     
            %{
            % use the multi-layer approach similar to Sachin's work. Fix
            % the parameter for the sensor, solve path planning. Then
            % refine the parameter until close to reality. In each
            % iteration, a convex program is solved. The initial solution
            % comes from ngPlanner
            
            % planing in non-Gaussian (GMM) belief space
            N = this.mpc_hor;
            dt = this.dt;
            
            % target 
            tar = fld.target;
            f = tar.f;
            del_f = tar.del_f;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            
            Q = tar.Q;
            
            % sensor
            h = this.h;    
            del_h = this.del_h;
            R = this.R; 
            
            % the parameter for the sensing boundary approximation
            alp = 1;
            alp_inc = 2; % increament paramter for alpha
            
            % set up simulation
            % robot state and control
            z = sdpvar(4,N+1,'full'); % robot state
            u = sdpvar(2,N,'full'); % robot control
            % estimation
            x = sdpvar(2*this.gmm_num,N+1,'full'); % target mean
            P = sdpvar(2*this.gmm_num,2*(N+1),'full'); % a set of 2-by-2 symmetric matrices
            
            % auxiliary variable
            %             tmp_M = sdpvar(2,2,'full');
%             K = sdpvar(2*this.gmm_num,2*N,'full');
            %             phi = sdpvar(2,2,'full');
            %             tmp1 = sdpvar(2,N,'full');
            t = sdpvar(this.gmm_num*this.gmm_num,N+1); % dummy variable for LMI
            slack = sdpvar(1);
            
            % debug purpose
            x_pred = sdpvar(2*this.gmm_num,N,'full');
            P_pred = sdpvar(2*this.gmm_num,2*N,'full');                       
            
            zref = init_sol.zref;
            uref = init_sol.uref;
            xref = init_sol.xref;
            Kref = init_sol.Kref;
            while (1)
                
                % obj
                obj = sum(sum(t))+slack;

                % constraints
                % epigraph for obj
                constr = [t>=0,slack>=0];
                for ii = 1:N
                    for jj = 1:this.gmm_num
                        tmp = 0;
                        for ll = 1:this.gmm_num
                            % LMI
                            constr = [constr,[P(2*ll-1:2*ll,2*ii+1:2*(ii+1)) x(2*jj-1:2*jj,ii+1)-x(2*ll-1:2*ll,ii+1);
                                (x(2*jj-1:2*jj,ii+1)-x(2*ll-1:2*ll,ii+1))' t(this.gmm_num*(jj-1)+ll,ii+1)]+slack*eye(3,3)>=0];
                        end                        
                    end
                end
                
                % initial value
                constr = [constr,z(:,1) == this.state];
                constr = [constr,x(:,1) == this.est_pos(:)];
                for jj = 1:this.gmm_num
                    constr = [constr,P(2*jj-1:2*jj,1:2) == this.P{jj}];%[1 0;0 1]];
                end
                
                % constraints on the go
                for ii = 1:N
                    % robot state
                    if isempty(zref)
                        constr = [constr,z(:,ii+1) == z(:,ii)+...
                            [z(4,ii)*cos(z(3,ii));z(4,ii)*sin(z(3,ii));...
                            u(:,ii)]*dt];
                    else
                        % linearize using previous result
                        constr = [constr,z(:,ii+1) == z(:,ii)+...
                            [z(4,ii)*cos(zref(3,ii))-zref(4,ii)*sin(zref(3,ii))*(z(3,ii)-zref(3,ii));
                            z(4,ii)*sin(zref(3,ii))+zref(4,ii)*cos(zref(3,ii))*(z(3,ii)-zref(3,ii));
                            u(:,ii)]*dt];
                    end
                    
                    constr = [constr,[fld.fld_cor(1);fld.fld_cor(3)]<=z(1:2,ii+1)<=...
                        [fld.fld_cor(2);fld.fld_cor(4)]];
                    
                    % use the weighted mean as the MAP of target position                   
                    if isempty(zref)
                        tmp_mean = reshape(x(:,ii+1),2,this.gmm_num)*this.wt;
                        gamma_den = 1; %1+exp(alp*(sum((tmp_mean-z(1:2,ii+1)).^2)-this.r^2));
                        % 1+sum((tmp_mean-z(1:2,ii+1)).^2);
                    else                        
                        tmp_mean = reshape(xref(:,ii+1),2,this.gmm_num)*this.wt;
                        tmp_v = tmp_mean-zref(1:2,ii+1);
                        gamma_den = 1; %%% temporarily set gamma to constant
%                         theta_ref = atan2(tmp_v(2),tmp_v(1)); % angle from the sensor to the target
%                         theta1 = zref(3,ii+1)-this.theta0;
%                         theta2 = zref(3,ii+1)+this.theta0;
%                         a1 = [sin(theta1);-cos(theta1)];
%                         a2 = [-sin(theta2);cos(theta2)];
%                         gamma_den = (1+exp(alp*(sum((tmp_v).^2)-this.r^2)))...
%                             *(1+exp(alp*(tmp_v'*a1)))*...
%                             (1+exp(alp*(tmp_v'*a2)));
%                         gamma_den = 1+(1+sum((tmp_mean-z(1:2,ii+1)).^2))*...
%                             (1+exp(-cos(z(3,ii+1)-theta_ref)+cos(this.theta0)));
                    end
                    gamma_num = 1;
                    
                    % target prediction
                    for jj = 1:this.gmm_num
                        A = del_f(x(2*jj-1:2*jj,ii));
                        if isempty (zref)
                            C = del_h(x(2*jj-1:2*jj,ii),z(1:2,ii));
                        else
                            C = del_h(xref(2*jj-1:2*jj,ii),zref(1:2,ii));
                        end
                        
                        % forward prediction
                        % mean
                        constr = [constr, x_pred(2*jj-1:2*jj,ii) == f(x(2*jj-1:2*jj,ii))];
                        % covariance
                        constr = [constr,P_pred(2*jj-1:2*jj,2*ii-1:2*ii) == A*(P(2*jj-1:2*jj,2*ii-1:2*ii))*A'+Q];
                        
%                         % update K using pesudo measurement
%                         T = C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)*C'+R; % C*P_pred*C'+R
%                         constr = [constr, K(2*jj-1:2*jj,2*ii-1:2*ii)*T == P_pred(2*jj-1:2*jj,2*ii-1:2*ii)*C']; % define K=P_pred*C'(C*P_pred*C'+T)^-1
                        
                        %                     a = T(1,1);
                        %                     b = T(1,2);
                        %                     c = T(2,1);
                        %                     d = T(2,2);
                        %                     t = a*d-b*c;
                        %                     T2 = [d -b; -c a]; % inv(CPC'+R)
                        
                        % since gamma is in factorial form, to avoid division, I
                        % separate the denominator and numerator to two sides of
                        % the equation
                        % mean
                        %%%%% note: for now, I assume the MAP as the target
                        %%%%% position, however, I should change this later
                        %%%%% when using GMM.
                        constr = [constr,x(2*jj-1:2*jj,ii+1) == x_pred(2*jj-1:2*jj,ii)];
                        % covariance
                        if isempty(zref)
                            constr = [constr,(P(2*jj-1:2*jj,2*ii+1:2*ii+2)-P_pred(2*jj-1:2*jj,2*ii-1:2*ii))*gamma_den...
                                == -gamma_num*Kref(2*jj-1:2*jj,2*ii-1:2*ii)*C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)];%+phi];
                        else
                            constr = [constr,(P(2*jj-1:2*jj,2*ii+1:2*ii+2)-P_pred(2*jj-1:2*jj,2*ii-1:2*ii))*gamma_den...
                                == -gamma_num*Kref(2*jj-1:2*jj,2*ii-1:2*ii)*C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)];%+phi];
                        end
                    end
                end
                constr = [constr, this.w_lb <= u(1,:) <= this.w_ub, this.a_lb <= u(2,:) <= this.a_ub...
                    this.v_lb <= z(4,:) <= this.v_ub];
                
                % use the result from last iteration as the initial
                % solution for current iteration
                
                if ~isempty(zref)
                    assign(z,zref)
                    assign(u,uref)
                end
                opt = sdpsettings('solver','mosek','verbose',3,'debug',1,'showprogress',1);
                
                sol1 = optimize(constr,obj,opt);
                zref = value(z);
                uref = value(u);
                
                % terminating condition: the actual in/out FOV is
                % consistent with that of planning
                is_in_fov = zeros(N,1);
                is_in_fov_approx = zeros(N,1);
                xref = value(x);
                tmp_rbt = this;
                %{
                for ii = 1:N
                    tmp_mean = reshape(xref(:,ii+1),2,this.gmm_num)*this.wt;
                    
                    tmp_rbt.state = zref(:,ii+1);
                    is_in_fov(ii) = tmp_rbt.inFOV(tmp_mean);
                    
                    tmp_v = tmp_mean-zref(1:2,ii+1);
                    theta_ref = atan2(tmp_v(2),tmp_v(1));
                    theta1 = zref(3,ii+1)-this.theta0;
                    theta2 = zref(3,ii+1)+this.theta0;
                    a1 = [sin(theta1);-cos(theta1)];
                    a2 = [-sin(theta2);cos(theta2)];
                    is_in_fov_approx(ii) = 1/((1+exp(alp*(sum((tmp_v).^2)-this.r^2)))...
                        *(1+exp(alp*(tmp_v'*a1)))*...
                        (1+exp(alp*(tmp_v'*a2))));
                    %(1+exp(-cos(zref(3,ii+1)-theta_ref)+cos(this.theta0))));
                end
                
                dif = norm(is_in_fov-is_in_fov_approx,1);
                if dif < 0.1*N
                    break
                end
                %}
                break
                
                alp = alp*alp_inc;
            end
            
            optz = zref;
            optu = uref;
            %}
        end
        
        function [optz,optu] = ngPlanner(this,fld)            
            % use the multi-layer approach similar to Sachin's work. Fix
            % the parameter for the sensor, solve path planning. Then
            % refine the parameter until close to reality.
            
            % planing in non-Gaussian (GMM) belief space
            N = this.mpc_hor;
            dt = this.dt;
            
            % target 
            tar = fld.target;
            f = tar.f;
            del_f = tar.del_f;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            
            Q = tar.Q;
            
            % sensor
            h = this.h;    
            del_h = this.del_h;
            R = this.R; 
            
            % the parameter for the sensing boundary approximation
            alp = 1;
            alp_inc = 2; % increament paramter for alpha
            
            % set up simulation
            % robot state and control
            z = sdpvar(4,N+1,'full'); % robot state
            u = sdpvar(2,N,'full'); % robot control
            % estimation
            x = sdpvar(2*this.gmm_num,N+1,'full'); % target mean
            P = sdpvar(2*this.gmm_num,2*(N+1),'full'); % a set of 2-by-2 symmetric matrices
            
            % auxiliary variable
            %             tmp_M = sdpvar(2,2,'full');
            K = sdpvar(2*this.gmm_num,2*N,'full');
            %             phi = sdpvar(2,2,'full');
            %             tmp1 = sdpvar(2,N,'full');
            
            % debug purpose
            x_pred = sdpvar(2*this.gmm_num,N,'full');
            P_pred = sdpvar(2*this.gmm_num,2*N,'full');                       
            
            zref = [];
            uref = [];
%             while (1)
                
                % obj
                obj = 0;%P(1,1,N+1)+P(2,2,N+1); % trace of last covariance
                for ii = 1:N
                    for jj = 1:this.gmm_num
                        tmp = 0;
                        for ll = 1:this.gmm_num
                            % obj uses the 0-order approximation
                            %%% I assume that the covariance does not change
                            %%% for now, which is the simplification. Will
                            %%% change this later after making program work.
                            if ll == jj
                                tmp = tmp+this.wt(ll)/(2*pi*det(this.P{ll}));
                            else
                                tmp = tmp+this.wt(ll)/(2*pi*det(this.P{ll}))*exp(-(x(2*jj-1:2*jj,ii+1)...
                                    -x(2*ll-1:2*ll,ii+1))'/this.P{ll}*(x(2*jj-1:2*jj,ii+1)-x(2*ll-1:2*ll,ii+1))/2);
                            end
                        end
                        obj = obj-this.wt(jj)*log(tmp); % missing term: 1/2*E((x-mu)^T*g''(mu)*(x-mu))
                    end
                end
                
                % constraints
                % initial value
                constr = [z(:,1) == this.state];
                constr = [constr,x(:,1) == this.est_pos(:)];
                for jj = 1:this.gmm_num
                    constr = [constr,P(2*jj-1:2*jj,1:2) == this.P{jj}];%[1 0;0 1]];
                end
                
                % constraints on the go
                for ii = 1:N
                    % robot state
                    if isempty(zref)
                        constr = [constr,z(:,ii+1) == z(:,ii)+...
                            [z(4,ii)*cos(z(3,ii));z(4,ii)*sin(z(3,ii));...
                            u(:,ii)]*dt];
                    else
                        % linearize using previous result
                        constr = [constr,z(:,ii+1) == z(:,ii)+...
                            [z(4,ii)*cos(zref(3,ii))-zref(4,ii)*sin(zref(3,ii))*(z(3,ii)-zref(3,ii));
                            z(4,ii)*sin(zref(3,ii))+zref(4,ii)*cos(zref(3,ii))*(z(3,ii)-zref(3,ii));
                            u(:,ii)]*dt];
                    end
                    
                    constr = [constr,[fld.fld_cor(1);fld.fld_cor(3)]<=z(1:2,ii+1)<=...
                        [fld.fld_cor(2);fld.fld_cor(4)]];
                    
                    % use the weighted mean as the MAP of target position
                    
                    if isempty(zref)
                        tmp_mean = reshape(x(:,ii+1),2,this.gmm_num)*this.wt;
                        gamma_den = 1;
                        %1+exp(alp*(sum((tmp_mean-z(1:2,ii+1)).^2)-this.r^2));
                        % 1+sum((tmp_mean-z(1:2,ii+1)).^2);
                    else                        
                        tmp_mean = reshape(xref(:,ii+1),2,this.gmm_num)*this.wt;
                        tmp_v = tmp_mean-zref(1:2,ii+1);
                        gamma_den = 1;
%                         theta_ref = atan2(tmp_v(2),tmp_v(1)); % angle from the sensor to the target
%                         theta1 = zref(3,ii+1)-this.theta0;
%                         theta2 = zref(3,ii+1)+this.theta0;
%                         a1 = [sin(theta1);-cos(theta1)];
%                         a2 = [-sin(theta2);cos(theta2)];
%                         gamma_den = (1+exp(alp*(sum((tmp_v).^2)-this.r^2)))...
%                             *(1+exp(alp*(tmp_v'*a1)))*...
%                             (1+exp(alp*(tmp_v'*a2)));
%                         gamma_den = 1+(1+sum((tmp_mean-z(1:2,ii+1)).^2))*...
%                             (1+exp(-cos(z(3,ii+1)-theta_ref)+cos(this.theta0)));
                    end
                    gamma_num = 1;
                    
                    % target prediction
                    for jj = 1:this.gmm_num
                        A = del_f(x(2*jj-1:2*jj,ii));
                        if isempty (zref)
                            C = del_h(x(2*jj-1:2*jj,ii),z(1:2,ii));
                        else
                            C = del_h(x(2*jj-1:2*jj,ii),zref(1:2,ii));
                        end
                        
                        % forward prediction
                        % mean
                        constr = [constr, x_pred(2*jj-1:2*jj,ii) == f(x(2*jj-1:2*jj,ii))];
                        % covariance
                        constr = [constr,P_pred(2*jj-1:2*jj,2*ii-1:2*ii) == A*(P(2*jj-1:2*jj,2*ii-1:2*ii))*A'+Q];
                        
                        % update using pesudo measurement
                        T = C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)*C'+R; % C*P_pred*C'+R
                        constr = [constr, K(2*jj-1:2*jj,2*ii-1:2*ii)*T == P_pred(2*jj-1:2*jj,2*ii-1:2*ii)*C']; % define K=P_pred*C'(C*P_pred*C'+T)^-1
                        
                        %                     a = T(1,1);
                        %                     b = T(1,2);
                        %                     c = T(2,1);
                        %                     d = T(2,2);
                        %                     t = a*d-b*c;
                        %                     T2 = [d -b; -c a]; % inv(CPC'+R)
                        
                        % since gamma is in factorial form, to avoid division, I
                        % separate the denominator and numerator to two sides of
                        % the equation
                        % mean
                        %%%%% note: for now, I assume the MAP as the target
                        %%%%% position, however, I should change this later
                        %%%%% when using GMM.
                        constr = [constr,x(2*jj-1:2*jj,ii+1) == x_pred(2*jj-1:2*jj,ii)];
                        % covariance
                        if isempty(zref)
                            constr = [constr,(P(2*jj-1:2*jj,2*ii+1:2*ii+2)-P_pred(2*jj-1:2*jj,2*ii-1:2*ii))*gamma_den...
                                == -gamma_num*K(2*jj-1:2*jj,2*ii-1:2*ii)*C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)];%+phi];
                        else
                            constr = [constr,(P(2*jj-1:2*jj,2*ii+1:2*ii+2)-P_pred(2*jj-1:2*jj,2*ii-1:2*ii))*gamma_den...
                                == -gamma_num*K(2*jj-1:2*jj,2*ii-1:2*ii)*C*P_pred(2*jj-1:2*jj,2*ii-1:2*ii)];%+phi];
                        end
                    end
                end
                constr = [constr, this.w_lb <= u(1,:) <= this.w_ub, this.a_lb <= u(2,:) <= this.a_ub...
                    this.v_lb <= z(4,:) <= this.v_ub];
                
                % use the result from last iteration as the initial
                % solution for current iteration
                
                if ~isempty(zref)
                    assign(z,zref)
                    assign(u,uref)
                end
                opt = sdpsettings('solver','ipopt','verbose',3,'debug',1,'showprogress',1);
                
                sol1 = optimize(constr,obj,opt);
                zref = value(z);
                uref = value(u);
                Kref = value(K);
                
                % terminating condition: the actual in/out FOV is
                % consistent with that of planning
                is_in_fov = zeros(N,1);
                is_in_fov_approx = zeros(N,1);
                xref = value(x);
                tmp_rbt = this;
                for ii = 1:N
                    tmp_mean = reshape(xref(:,ii+1),2,this.gmm_num)*this.wt;
                    
                    tmp_rbt.state = zref(:,ii+1);
                    is_in_fov(ii) = tmp_rbt.inFOV(tmp_mean);
                    
                    tmp_v = tmp_mean-zref(1:2,ii+1);
                    theta_ref = atan2(tmp_v(2),tmp_v(1));
                    theta1 = zref(3,ii+1)-this.theta0;
                    theta2 = zref(3,ii+1)+this.theta0;
                    a1 = [sin(theta1);-cos(theta1)];
                    a2 = [-sin(theta2);cos(theta2)];
                    is_in_fov_approx(ii) = 1/((1+exp(alp*(sum((tmp_v).^2)-this.r^2)))...
                        *(1+exp(alp*(tmp_v'*a1)))*...
                        (1+exp(alp*(tmp_v'*a2))));
                    %(1+exp(-cos(zref(3,ii+1)-theta_ref)+cos(this.theta0))));
                end
                
                dif = norm(is_in_fov-is_in_fov_approx,1);
%                 if dif < 0.1*N
%                     break
%                 end
                
                alp = alp*alp_inc;
%             end
            
%             optz = zref;
%             optu = uref;
            %}
            
            % check the singularity of P
            for ii = 1:N
                for jj = 1:this.gmm_num
                    display(cond(value(P(2*jj-1:2*jj,2*ii+1:2*ii+2))))
                end
            end
            
            display(value(P))
                
            init_sol = struct('zref',zref,'uref',uref,'Kref',Kref,'xref',xref);
            [optz,optu] = cvxPlanner(this,fld,init_sol);
            
        end
        
        function [optz,optu] = Planner(this,fld)
            %{
            N = this.mpc_hor;
            var_dt = this.dt;
            var_C = this.C;
            var_R = this.R;
            st = this.state;
            x_cur = this.est_pos;
            gam = this.gam;
            
            tar = fld.target;
            A = tar.A;
            Q = tar.Q;
            
            % set up simulation
            % robot state and control
            z = sdpvar(4,N+1,'full');
            u = sdpvar(2,N,'full');
            % estimation
            x = sdpvar(2,N+1,'full');
            var_P = sdpvar(2,2*(N+1),'full'); % symmetric matrix in first two dim
            % auxiliary variable
            tmp_M = sdpvar(2,2,'full');
            K = sdpvar(2,2,'full');
            phi = sdpvar(2,2,'full');
            tmp1 = sdpvar(2,N,'full');
            
            % debug purpose
            x_pred = sdpvar(2,N,'full');
%             P_pred = sdpvar(2,2,N,'full');
            P_pred = sdpvar(2,2*N,'full');
            
            % obj
            obj = 0;%P(1,1,N+1)+P(2,2,N+1); % trace of last covariance
            
            % constraints
            constr = [z(:,1) == this.state];
            constr = [constr,x(:,1) == this.est_pos];
            constr = [constr,var_P(:,1:2) == this.P];%[1 0;0 1]];
%             constr = [constr,var_P(:,:,1) == [1 0;0 1]];%this.P];
            
            for ii = 1:N
                obj = obj+var_P(1,2*ii+1)+var_P(2,2*ii+2)+((z(1:2,ii+1)-x_cur)'*tmp1(:,ii)-0.5)^2;%var_P(1,1,ii+1)^2+var_P(2,2,ii+1)^2+sum(sum(phi.^2));
                
%                 constr = [constr,P(:,:,ii+1)>=0];
                
                % robot state
                constr = [constr,z(:,ii+1) == z(:,ii)+...
                    [z(4,ii)*cos(z(3,ii));z(4,ii)*sin(z(3,ii));...
                    u(:,ii)]*var_dt];
                
                constr = [constr,[fld.fld_cor(1);fld.fld_cor(3)]<=z(1:2,ii+1)<=...
                    [fld.fld_cor(2);fld.fld_cor(4)]];
                
                constr = [constr, tmp1(:,ii)==z(1:2,ii+1)-x_cur];
                
                % KF update
%                 alp1 = z(3,ii+1) - this.theta0;
%                 alp2 = z(3,ii+1) + this.theta0;
                alp1 = st(3) - this.theta0;
                alp2 = st(3) + this.theta0;
                a = [sin(alp1),-cos(alp1);-sin(alp2),cos(alp2)]; % [a1;a2]
                b = [z(1,ii+1)*sin(alp1)-z(2,ii+1)*cos(alp1);-z(1,ii+1)*sin(alp2)+z(2,ii+1)*cos(alp2)];%[b1;b2];
                
%                 alp1 = st(3) - this.theta0;
%                 alp2 = st(3) + this.theta0;
%                 a = [sin(alp1),-cos(alp1);-sin(alp2),cos(alp2)]; % [a1;a2]
%                 b = [-st(1)*sin(alp1)+st(2)*cos(alp1);st(1)*sin(alp2)-st(2)*cos(alp2)];%[b1;b2];
                
%                 delta = 1;%/((1+exp(gam*(a(1,:)*x(:,ii)-b(1))))*(1+exp(gam*(a(2,:)*x(:,ii)-b(2))))*...
%                     (1+exp(gam*(sum((x(:,ii)-this.state(1:2)).^2)-this.r^2))));
%                 delta_rcp = (1+exp(gam*(a(1,:)*x(:,ii)-b(1))))*(1+exp(gam*(a(2,:)*x(:,ii)-b(2))))*...
%                     (1+exp(gam*(sum((x(:,ii)-this.state(1:2)).^2)-this.r^2)));
%                 D = ...%(1+exp(gam*(a(1,:)*x(:,ii)-b(1))))*(1+exp(gam*(a(2,:)*x(:,ii)-b(2))))*...
%                     (1+exp(gam*(sum((x(:,ii)-this.state(1:2)).^2)-this.r^2)));
%                 dist_prod = (gam*(a(1,:)*x(:,ii)-b(1)))^2;%(gam*(a(1,:)*x(:,ii)-b(1))*gam*(a(2,:)*x(:,ii)-b(2))*...
% %                     gam*(sum((x(:,ii)-this.state(1:2)).^2)-this.r^2))^2;
%                 dist_prod2 = (1+(gam*(a(1,:)*x(:,ii)-b(1)))^2);%*(1+(gam*(a(2,:)*x(:,ii)-b(2)))^2)*...
% %                     (1+(gam*(sum((x(:,ii)-this.state(1:2)).^2)-this.r^2))^2);
                dist_prod = 1;% (sqrtm(sum((x(:,ii)-this.state(1:2))).^2)-this.r)^2;%(gam*(a(1,:)*x_cur-b(1)))^2*(gam*(a(2,:)*x(:,ii)-b(2)))^2;%(gam*(a(1,:)*x(:,ii)-b(1))*gam*(a(2,:)*x(:,ii)-b(2))*...
%                     gam*(sum((x(:,ii)-this.state(1:2)).^2)-this.r^2))^2;
%                 dist_prod2 = (1+exp(-(-a(1,:)*x(:,ii)+b(1))))*...%                 (1+(gam*(a(1(x_cur-b(1)))^2)*(1+(gam*(a(2,:)*x(:,ii)-b(2)))^2);%*...
%                     (1+sum((x(:,ii)-this.state(1:2)).^2))/100;%(1+(sqrtm(sum((x(:,ii)-this.state(1:2)).^2))-this.r)^2);
                dist_prod2 = (1+(a(1,:)*x_cur-b(1))^2)*(1+(a(2,:)*x_cur-b(2))^2)*...
                    (1+sum((x_cur-z(1:2,ii+1)).^2))/100;%(1+(sqrtm(sum((x(:,ii)-this.state(1:2)).^2))-this.r)^2);
                

                % prediction
                x_pred(:,ii) = A*x(:,ii);
%                 P_pred(:,:,ii) = A*var_P(:,:,ii)*A'+Q;
                P_pred(:,2*ii-1:2*ii) = A*var_P(:,2*ii-1:2*ii)*A'+Q;
                
                % update
% %                 K = P_pred*C'*delta*tmp_M*delta;
% %                 constr = [constr,K == 1];
% %                 constr = [constr,K*(var_C*P_pred(:,:,ii)*var_C'+var_R/delta^2)==P_pred(:,:,ii)*var_C'];
%                 constr = [constr,K*(var_C*P_pred(:,2*ii-1:2*ii)*var_C'+var_R/delta^2)==P_pred(:,2*ii-1:2*ii)*var_C'];
% %                 constr = [constr,K*(C*P_pred(:,:,ii)*C'+R*D^2)==P_pred(:,:,ii)*C'];
%                 constr = [constr,x(:,ii+1) == x_pred(:,ii)+K*(var_C*x(:,ii)-var_C*x_pred(:,ii))];
% %                 constr = [constr,x(:,ii+1) == x_pred+K*(C*x_cur-C*x_pred)];
% %                 constr = [constr,var_P(:,:,ii+1) == P_pred(:,:,ii)-K*var_C*P_pred(:,:,ii)+phi];
%                 constr = [constr,var_P(:,2*ii+1:2*ii+2) >= P_pred(:,2*ii-1:2*ii)-K*var_C*P_pred(:,2*ii-1:2*ii)];%+phi];
% %                 constr = [constr,(delta*C*P_pred(:,:,ii)*C'*delta+R)*tmp_M == eye(2)];
                
%                 % test version of simplified constraint
%                 T = var_C*P_pred(:,2*ii-1:2*ii)*var_C'+var_R*delta_rcp^2;
%                 a = T(1,1);
%                 b = T(1,2);
%                 c = T(2,1);
%                 d = T(2,2);
%                 t = a*d-b*c;
%                 T2 = [d -b; -c a];
%                 constr = [constr,(x(:,ii+1)-x_pred(:,ii))*t == P_pred(:,2*ii-1:2*ii)*var_C'*T2*(var_C*x(:,ii)-var_C*x_pred(:,ii))];
%                 constr = [constr,(var_P(:,2*ii+1:2*ii+2)-P_pred(:,2*ii-1:2*ii))*t...
%                     == -P_pred(:,2*ii-1:2*ii)*var_C'*T2*var_C*P_pred(:,2*ii-1:2*ii)];%+phi];
                
                % use x/sqrt(1+x^2) as sigmoid function and Sachin's
                % formulation
%                 T = var_C*P_pred(:,2*ii-1:2*ii)*var_C'*dist_prod+var_R*dist_prod2;
%                 a = T(1,1);
%                 b = T(1,2);
%                 c = T(2,1);
%                 d = T(2,2);
%                 t = a*d-b*c;
%                 T2 = [d -b; -c a];
% %                 constr = [constr,(x(:,ii+1)-x_pred(:,ii))*t == dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*(var_C*x(:,ii)-var_C*x_pred(:,ii))];
% %                 constr = [constr,(var_P(:,2*ii+1:2*ii+2)-P_pred(:,2*ii-1:2*ii))*t...
% %                     == -dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*var_C*P_pred(:,2*ii-1:2*ii)];%+phi];
%                 constr = [constr,(x(:,ii+1)-x_pred(:,ii))*t*dist_prod2 == P_pred(:,2*ii-1:2*ii)*var_C'*T2*(var_C*x(:,ii)-var_C*x_pred(:,ii))/100];
%                 constr = [constr,(var_P(:,2*ii+1:2*ii+2)-P_pred(:,2*ii-1:2*ii))*t*dist_prod2...
%                     == -P_pred(:,2*ii-1:2*ii)*var_C'*T2*var_C*P_pred(:,2*ii-1:2*ii)/100];%+phi];
                
                % use Schenato's formulation
                T = var_C*P_pred(:,2*ii-1:2*ii)*var_C'+var_R;
                a = T(1,1);
                b = T(1,2);
                c = T(2,1);
                d = T(2,2);
                t = a*d-b*c;
                T2 = [d -b; -c a];
                constr = [constr,(x(:,ii+1)-x_pred(:,ii))*dist_prod2*t == dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*(var_C*x(:,ii)-var_C*x_pred(:,ii))/100];
                constr = [constr,(var_P(:,2*ii+1:2*ii+2)-P_pred(:,2*ii-1:2*ii))*dist_prod2*t...
                    == -dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*var_C*P_pred(:,2*ii-1:2*ii)/100];%+phi];
            end
            constr = [constr, this.w_lb <= u(1,:) <= this.w_ub, this.a_lb <= u(2,:) <= this.a_ub];
            
            opt = sdpsettings('solver','ipopt','verbose',3,'debug',1,'showprogress',1);
            
            sol = optimize(constr,obj,opt);
            optz = value(z);
            optu = value(u);
            %}
        end

        function [optz,optu] = Planner2(this,fld)
            %{
            % two layer process
            
            N = this.mpc_hor;
            var_dt = this.dt;
            var_C = this.C;
            var_R = this.R;
%             st = this.state;
            x_cur0 = this.est_pos;
            gam = this.gam;
            
            tar = fld.target;
            A = tar.A;
            B = tar.B;
            Q = tar.Q;
            
            % set up simulation
            % robot state and control
            z = sdpvar(4,N+1,'full');
            u = sdpvar(2,N,'full');
            % estimation
            x = sdpvar(2,N+1,'full');
            var_P = sdpvar(2,2*(N+1),'full'); % symmetric matrix in first two dim
            % auxiliary variable
            tmp_M = sdpvar(2,2,'full');
            K = sdpvar(2,2,'full');
            phi = sdpvar(2,2,'full');
            tmp1 = sdpvar(2,N,'full');
            
            % debug purpose
            x_pred = sdpvar(2,N,'full');
%             P_pred = sdpvar(2,2,N,'full');
            P_pred = sdpvar(2,2*N,'full');
            
            % obj
            obj = 0;%P(1,1,N+1)+P(2,2,N+1); % trace of last covariance
            
            % constraints
            constr0 = [z(:,1) == this.state];
            constr0 = [constr0,x(:,1) == this.est_pos];
            constr0 = [constr0,var_P(:,1:2) == this.P];%[1 0;0 1]];
%             constr0 = [constr0,var_P(:,:,1) == [1 0;0 1]];%this.P];
            
            x_cur = x_cur0;
            for ii = 1:N
                x_cur = A*x_cur+B;
                obj = obj+var_P(1,2*ii+1)+var_P(2,2*ii+2)+((z(1:2,ii+1)-x_cur)'*tmp1(:,ii));%var_P(1,1,ii+1)^2+var_P(2,2,ii+1)^2+sum(sum(phi.^2));
                
%                 constr0 = [constr0,P(:,:,ii+1)>=0];
                
                % robot state
                constr0 = [constr0,z(:,ii+1) == z(:,ii)+...
                    [z(4,ii)*cos(z(3,ii));z(4,ii)*sin(z(3,ii));...
                    u(:,ii)]*var_dt];
                
                constr0 = [constr0,[fld.fld_cor(1);fld.fld_cor(3)]<=z(1:2,ii+1)<=...
                    [fld.fld_cor(2);fld.fld_cor(4)]];
                
                constr0 = [constr0, tmp1(:,ii)==z(1:2,ii+1)-x_cur];
            end
            constr0 = [constr0, this.w_lb <= u(1,:) <= this.w_ub, this.a_lb <= u(2,:) <= this.a_ub...
                this.v_lb <= z(4,:) <= this.v_ub];
            
            % first layer
            display('layer 1')
            constr1 = constr0;
            x_cur = x_cur0;
            for ii = 1:N
                x_cur = A*x_cur+B;
                dist_prod = 1;
                dist_prod2 = (1+sum((x_cur-z(1:2,ii+1)).^2))/100;
                
                % prediction
                x_pred(:,ii) = A*x(:,ii)+B;
%                 P_pred(:,:,ii) = A*var_P(:,:,ii)*A'+Q;
                constr1 = [constr1,P_pred(:,2*ii-1:2*ii) == A*var_P(:,2*ii-1:2*ii)*A'+Q];
                
                T = var_C*P_pred(:,2*ii-1:2*ii)*var_C'+var_R;
                a = T(1,1);
                b = T(1,2);
                c = T(2,1);
                d = T(2,2);
                t = a*d-b*c;
                T2 = [d -b; -c a];
%                 constr1 = [constr1,(x(:,ii+1)-x_pred(:,ii))*dist_prod2*t == dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*(var_C*x(:,ii)-var_C*x_pred(:,ii))/10];
                constr1 = [constr1, x(:,ii+1) == A*x(:,ii)+B];
                constr1 = [constr1,(var_P(:,2*ii+1:2*ii+2)-P_pred(:,2*ii-1:2*ii))*dist_prod2*t...
                    == -dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*var_C*P_pred(:,2*ii-1:2*ii)/100];%+phi];
            end
            
            opt = sdpsettings('solver','ipopt','verbose',3,'debug',1,'showprogress',1);
            
            sol1 = optimize(constr1,obj,opt);
            zref = value(z);            
            optz = value(z);
            optu = value(u);
            
            % second layer
            %
            display('layer 2')
            
            constr2 = constr0;
            theta_ref = zeros(N,1);
            x_cur = x_cur0;
            for ii = 1:N
                x_cur = A*x_cur+B;
%                 alp1 = z(3,ii+1) - this.theta0;
%                 alp2 = z(3,ii+1) + this.theta0;
%                 a = [sin(alp1),-cos(alp1);-sin(alp2),cos(alp2)]; % [a1;a2]
%                 b = [zref(1,ii+1)*sin(alp1)-zref(2,ii+1)*cos(alp1);-zref(1,ii+1)*sin(alp2)+zref(2,ii+1)*cos(alp2)];%[b1;b2];
%                 dist_prod = 1;
%                 dist_prod2 = ((1+exp((a(1,:)*x_cur-b(1))))*(1+exp((a(2,:)*x_cur-b(2)))))/100;%*(1+sum((x_cur-z(1:2,ii+1)).^2))/100;
                
                ang_dif = x_cur-zref(1:2,ii+1);
                theta_ref(ii) = atan2(ang_dif(2),ang_dif(1));
                dist_prod = 1;
                dist_prod2 = (1+sum((x_cur-z(1:2,ii+1)).^2))*...
                    (1+exp(-cos(z(3,ii+1)-theta_ref(ii))+cos(this.theta0)))/100;
                
                
                % prediction
                x_pred(:,ii) = A*x(:,ii)+B;
%                 P_pred(:,:,ii) = A*var_P(:,:,ii)*A'+Q;
                constr2 = [constr2, P_pred(:,2*ii-1:2*ii) == A*var_P(:,2*ii-1:2*ii)*A'+Q];
                
                T = var_C*P_pred(:,2*ii-1:2*ii)*var_C'+var_R;
                a = T(1,1);
                b = T(1,2);
                c = T(2,1);
                d = T(2,2);
                t = a*d-b*c;
                T2 = [d -b; -c a];
%                 constr2 = [constr2,(x(:,ii+1)-x_pred(:,ii))*dist_prod2*t == dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*(var_C*x(:,ii)-var_C*x_pred(:,ii))/10];
                constr2 = [constr2, x(:,ii+1) == A*x(:,ii)+B];
                constr2 = [constr2,(var_P(:,2*ii+1:2*ii+2)-P_pred(:,2*ii-1:2*ii))*dist_prod2*t...
                    == -dist_prod*P_pred(:,2*ii-1:2*ii)*var_C'*T2*var_C*P_pred(:,2*ii-1:2*ii)/100];%+phi];
            end
            opt = sdpsettings('solver','ipopt','verbose',3,'debug',1,'showprogress',1);
            
            sol2 = optimize(constr2,obj,opt);
            optz = value(z);
            optu = value(u);
            %}
        end
        
        %% robot state updating
        function this = updState(this,u)
            st = this.state;
            this.optu = [this.optu,u(:,1)];
            dt = this.dt;
            this.state = st+[st(4)*cos(st(3));st(4)*sin(st(3));u(:,1)]*dt;
            this.traj = [this.traj,this.state];
            % range-bearing sensor
            this.h = @(x) x-this.state(1:2);
        end
    end
end