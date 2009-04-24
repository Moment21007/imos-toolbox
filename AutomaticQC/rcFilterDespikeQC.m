function [data flags log] = ...
rcFilterDespikeQC( sample_data, cal_data, data, k, varargin )
%RCFILTERDESPIKEQC Uses an RC filter technique to detect spikes in the given
%data.
%
% This function applies a spike detection filter based on the RC filter 
% despiking method described in:
%
%   Goring DG & Nikora VI 2002 'Despiking Acoustic Doppler Velocimeter Data',
%   Journal of Hydraulic Engineering, January 2002, vol 128, issue 1, 
%   pp 117-126.
%
% Inputs:
%   sample_data - struct containing the entire data set and dimension data.
%
%   cal_data    - struct which contains calibration and metadata.
%
%   data        - the vector of data to check.
%
%   k           - Index into the cal_data/sample_data.parameters vectors.
%
%   'k_param'   - Filter parameter (see the journal article). If not provided,
%                 a default value of 3 is used.
%
% Outputs:
%   data        - same as input.
%
%   flags       - Vector the same length as data, with flags for corresponding
%                 data which has been detected as spiked.
%
%   log         - Empty cell array.
%
% Author: Paul McCarthy <paul.mccarthy@csiro.au>
%

%
% Copyright (c) 2009, eMarine Information Infrastructure (eMII) and Integrated 
% Marine Observing System (IMOS).
% All rights reserved.
% 
% Redistribution and use in source and binary forms, with or without 
% modification, are permitted provided that the following conditions are met:
% 
%     * Redistributions of source code must retain the above copyright notice, 
%       this list of conditions and the following disclaimer.
%     * Redistributions in binary form must reproduce the above copyright 
%       notice, this list of conditions and the following disclaimer in the 
%       documentation and/or other materials provided with the distribution.
%     * Neither the name of the eMII/IMOS nor the names of its contributors 
%       may be used to endorse or promote products derived from this software 
%       without specific prior written permission.
% 
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE 
% LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
% ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
% POSSIBILITY OF SUCH DAMAGE.
%

error(nargchk(4, 6, nargin));
if ~isstruct(sample_data),        error('sample_data must be a struct'); end
if ~isstruct(cal_data),           error('cal_data must be a struct');    end
if ~isvector(data),               error('data must be a vector');        end
if ~isscalar(k) || ~isnumeric(k), error('k must be a numeric scalar');   end

p = inputParser;
p.addOptional('k_param', 3, @isnumeric);

p.parse(varargin{:});

k_param = p.Results.k_param;

% we need to modify the data set, so work with a copy
fdata = data;

goodFlag  = imosQCFlag('good',  cal_data.qc_set);
spikeFlag = imosQCFlag('spike', cal_data.qc_set);

flags    = zeros(length(fdata), 1);
flags(:) = goodFlag;
log      = {};

% remove the mean and run a mild high pass filter 
% over the data before applying spike detection
fdata = highPassFilter(fdata, 0.99);
fdata = fdata - mean(fdata);

% we need four data sets:
%   - lowpass(data)
%   - square(data)
%   - lowpass(square(data))
%   - square(lowpass(data))
%
% We use a fairly extreme low pass filter to reduce the 
% likelihood of insignificant spikes being flagged

lp   = lowPassFilter(fdata, 0.2);
sq   = fdata .* fdata;
lpsq = lowPassFilter(sq, 0.2);
sqlp = lp .* lp;

for m = 1:(length(fdata) - 1)

  variance = lpsq(m) - sqlp(m);

  % check that data is good
  low_bound  = lp(m) - (k_param * (variance .^ 0.5));
  high_bound = lp(m) + (k_param * (variance .^ 0.5));

  % if bad, flag it
  if fdata(m+1) <= low_bound || fdata(m+1) >= high_bound

    flags(m+1) = spikeFlag;
    
  end
end