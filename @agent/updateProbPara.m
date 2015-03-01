function [w,mu,sigma] = updateProbPara(agent,w,mu,sigma,obs,mu_s,sigma_s)
num = length(w);
if obs == 1 % positive observation
    for ii = 1:num      
        tmp_sigma = inv(inv(sigma_s)+inv(sigma(:,:,ii)));
        tmp_mu = tmp_sigma*(sigma_s\mu_s+sigma(:,:,ii)\mu(ii));        
        alpha_i = A(tmp_mu,tmp_sigma)-A(mu(ii),sigma(:,:,ii))-A(mu_s,sigma_s);
        w(ii) = w(ii)*exp(alpha_i);
        mu(ii) = tmp_mu;
        sigma(ii) = tmp_sigma;        
    end
    w = w/(sum(w)); % normalize weights
elseif obs == 0 % negative observation
    w = [w;w]; % negative observation doubles the number of gaussian distribution
    mu = [mu,mu];
    sigma = cat(3,sigma,sigma);
    % update the mean and covariance for the second half parameters. 
    % The first half don't change except the weights
    for ii = num+1:2*num 
        tmp_sigma = inv(inv(sigma_s)+inv(sigma(:,:,ii)));
        tmp_mu = tmp_sigma*(sigma_s\mu_s+sigma(:,:,ii)\mu(:,ii));
        alpha_i = A(tmp_mu,tmp_sigma)-A(mu(:,ii),sigma(:,:,ii))-A(mu_s,sigma_s);
        w(ii) = -w(ii)*exp(alpha_i);
        mu(:,ii) = tmp_mu;
        sigma(:,:,ii) = tmp_sigma;        
    end
    w = w/sum(w);
end
end

function value = A(mu,sigma)
% log partition function in exponential family for Gaussian distribution
value = 1/2*mu'*(sigma\mu)+1/2*log(det(sigma))+1/2*log(2*pi);
end    