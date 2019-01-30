function [Pproj, Xproj] = factorization_method(xh, points_views, lambda_init)
% Implements the factorization method from [Sturm96] to do projective
% reconstruction (recover projective structure + motion).
%
% Inputs
%   - xh:             a matrix of 3*Ncam x Npoints corresponding to
%                     each view.
%                     (1-2, 2-3, 3-4,..., m-1-m).
%   - points_views:   location of the keypoints found for each view.
%                     It has size 2 x Npoints (i.e.: non homogeneous).
%   -
%
% Outputs
%   - Pproj:          3*Ncam x 4 matrix containing the camera matrices.
%   - Xproj:          4 x Npoints matrix of homogeneous coordinates of 3D points.
%
% References
%
% [Sturm96]: "A Factorization Based Algorithm for Multi-Image Projective Structure and
% Motion", Peter Sturm and Bill Triggs.
%
% [Har95]: "Multiple view geometry in Computer Vision", Richard Hartley and
% Andrew Zisserman.

%% Step 0: some initializations
Ncam = size(xh, 1)/3;  % a.k.a. 'Ncam'
Npoints = size(xh, 2);
ransac_thr = 2.0;  % test different values if needed
%% Step 1: normalise image coordinates (centroid at origin, dist. sqrt(2))
% Is this really needed if the Normalized 8-point algorithm already does
% this?
xh_norm = zeros(size(xh));
T = struct(Ncam,1);
for i = 1:3:Ncam
  [xh_norm(i:i+2,:), T{i}] = normalise2dpts(xh(i:i+2,:));
end

% Note: step 2 only needed if in step 3 we use lambdas!= 1
if strcmpi(lambda_init, 'SturmAndTriggs')
  %% Step 2: compute fundamental matrix/ces with the Robust 8-point algorithm*
  % * maybe to speed up this we'll need to use "only" the Normalised version.
%   Fr = struct(Ncam-1,1);
%   idx_inliers = struct(Ncam-1,1);
  %
  %   iref = 1;  % we apply the same constraint as [Sturm96]: the images are taken
  % pairwise in sequence, F12, F23, F34,..., Fm-1m
  %   for i = 1:Ncam-1
  %     x1 = points_views{i}(:, xh_norm(3*i-2, :));
  %     x2 = points_views{i+1}(:, xh_norm(3*i-1, :));
  %     % TODO: compute epipoles to determine lambda's.
  %     [Fr{i}, idx_inliers{i}, ] = ransac_fundamental_matrix(homog(x1), homog(x2), ransac_thr);
  %     % F = fundamental_matrix(homog(x1), homog(x2));  % Normalized 8-point algorithm
  %   end
  %TODO: first naive implementation, naïve loops for all views and all points
  lambda = ones(Ncam, Npoints);  % Lambda for the first view is 1
  iref = 1;
  for i = 2:Ncam
    xref = points_views{iref}(:, xh_norm(3*iref-2, :));
    xi = points_views{i}(:, xh_norm(3*i-1, :));
    [Fri, ~, eri, eir] = ransac_fundamental_matrix(homog(x1), homog(x2), ransac_thr);
%% Step 3: determine scale factors (lambda's) via eq(3) of [Sturm96]
    for p = 1:Npoints
      xrp = xref(:,p);
      xip = xi(:,p);
      cross_eri_xip = cross(eri, xip);
      lambda(i,p) = lambda(iref,p) * abs((xrp' * Fri * cross_eri_xip)/(cross_eri_xip' * cross_eri_xip));
    end
    iref = i;  % Update reference image.
  end
  
elseif strcmpi(lambda_init, 'ones')  % All lambda(i,j) set to 1
  lambda = ones(size(xh));
else
  error('Non-valid weight-initialization method. ''ones'' or ''sturm'' are allowed\n');
end


% TODO: embed following steps in a while() loop until convergence
coverged = false;
d = 1000;
while ~converged
  %% Step 4: build the rescaled measurement matrix W
  % W has size 3m x n and rank<=4
  W = lambda .* xh_norm;
  
  %% Step 5: balance W by column and "triplet-of-rows"-wise normalisation
  % [Sturm96] states a 3-step normalisation:
  %   1. Rescale each column l so that sum(wrl.^2) = 1
  %   2. Rescale each triplet of rows (3k-2,3k-1,3k) so sum(sum(wil.^2))=1
  %   3. If the entries of W changed "significantly", repeat 1 and 2.
  
  % Note: we follow the suggested approach in [Har95] (set rows-wise norms
  % to 1 and then set columns similarly, in two passes). Notice that by
  % doing this, we are not explicitly implementing point 3 above.
  
  % Note 2: in [Sturm96], the authors say that balancing lambda alone would
  % be enough as we are working with normalised image coordinates (instead of
  % W as a whole). We may want to try this in the future and compare both results.
  
  p = 2;  % Norm used, here L2.
  % 1. Normalise rows
  rows_norm = vecnorm(W, p, 2);
  W_b = W ./ repmat(rows_norm, [1, size(W,2)]);
  % 2. Normalise columns
  cols_norm = vecnorm(W_b, p, 1);
  W_b = W_b ./ repmat(cols_norm, [size(W_b,1), 1]);
  
  %% Step 6: compute the SVD of balanced W
  [U,D,V] = svd(W_b);
  % Force W_b to have rank 4 by setting eigenvalues i>4 to 0
  D4 = diag(D);
  Sigma = D4(1:4);  % not used as Sigma = Sigma_p * Sigma_pp
  Sigma_p = sqrt(D4(1:4));
  Sigma_pp = Sigma_p;
  % Decomp of W.
  % W = U' * Sigma_p * Sigma_pp * V' = U_hat * V_hat
  % where U' contains the first 4 columns of U, V' the first 4 rows of V
  W_b = U(:,1:4) * Sigma_p * Sigma_pp * V(1:4,:);
  
  %% Step 7: recover projective motion + shape from SVD decomposition
  % Identify motion and shape from SVD
  % From above, one can relate U_hat to a set of m projection matrices and
  % V_hat to a set of Npoints.
  P_hat = U(:,1:4) * Sigma_p;
  X_hat = Sigma_pp * V(1:4,:);
  
  % Compute reprojection error
  d_old = d;
  % Euclidean distance, make sure that we are using Euclidean coordinates!
  d = sum(sqrt(sum((xh_norm - (P_hat * X_hat)) .^2)));
  converged = (abs(d - d_old) / d) < 0.1;
  if ~converged
    % Update lambda
    lambda = P_hat * X_hat;
  end
end

%% Step 8: adapt projective motion (Pi) accounting for Ti => denormalise
% The points X_proj are not changed.
% Pi_hat' = inv(Ti) * Pi_hat
Pproj = zeros(3 * Ncam, 4);
for i = 1:Ncam
  aux = T{i} \ P_hat;
  Pproj(3*i-2:3*i, :) = aux;
end

Xproj = X_hat;

end