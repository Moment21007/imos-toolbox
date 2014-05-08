function sample_data = VemcoParse( filename, mode )
%VemcoParse Parses a .csv data file from a Vemco Minilog-II-T logger.
%
% This function is able to read in a .csv data file produced via an export
% option of the Vemco Logger Vue software. It reads specific instrument header 
% format and makes use of a lower level function readVemcoCsv to convert the data. 
% The files consist of two sections:
%
%   - processed header  - header information generated by Logger Vue software.
%                         Typically first 8 lines.
%   - data              - Rows of comma seperated data.
%
% This function reads in the header sections, and delegates to the two file
% specific sub functions to process the data.
%
% Inputs:
%   filename    - cell array of files to import (only one supported).
%   mode        - Toolbox data type mode ('profile' or 'timeSeries').
%
% Outputs:
%   sample_data - Struct containing sample data.
%
% Code based on SBE37SMParse.m
%
% Author:       Simon Spagnol <s.spagnol@aims.gov.au>
% Contributor:  Guillaume Galibert <guillaume.galibert@utas.edu.au>

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
error(nargchk(1,2,nargin));

if ~iscellstr(filename)
    error('filename must be a cell array of strings');
end

% only one file supported currently
filename = filename{1};

% read in every line of header in the file, then big read of data
procHeaderLines = {};
dataLines       = {};
try
    % not sure if Vemco csv files are the same as I only have one 
    % type to test on, so assume that the last line in header region 
    % is Date Time line.
    fid = fopen(filename, 'rt');
    line = fgetl(fid);
    while ischar(line) && isempty(regexp(line,'^Date','once'))
        line = deblank(line);
        if isempty(line)
            line = fgetl(fid);
            continue;
        end
        procHeaderLines{end+1} = line;
        line = fgetl(fid);
    end
    dataHeaderLine=line;
    
    % assume date and time would always be the first and second column, if
    % not will need to make a regexp for dataHeaderLine and get the index
    iDate=1;
    iTime=2;
    iDateTimeCol=[iDate iTime];
    ncolumns=numel(regexp(dataHeaderLine,',','split'));
    iProcCol=setdiff([1:ncolumns],iDateTimeCol);
    
    % consruct a format string using %s for date and time, and %f32 for
    % everything else
    formatstr = '';
    for k = 1:ncolumns
        if ismember(k,iDateTimeCol)
            formatstr = [formatstr '%s'];
        else
            formatstr = [formatstr '%f32'];
        end
    end
    
    dataLines = textscan(fid,formatstr,'Delimiter',',');
    
    fclose(fid);
    
catch e
    if fid ~= -1, fclose(fid); end
    rethrow(e);
end

% read in the raw instrument header
procHeader = parseProcessedHeader( procHeaderLines, dataHeaderLine);
procHeader.toolbox_input_file = filename;

% use Vemco specific csv reader function
[data, comment] = readVemcoCsv(dataLines, procHeader);

% create sample data struct,
% and copy all the data in
sample_data = struct;

sample_data.toolbox_input_file  = filename;
sample_data.meta.procHeader     = procHeader;

sample_data.meta.instrument_make = 'Vemco';
if isfield(procHeader, 'instrument_model')
    sample_data.meta.instrument_model = procHeader.instrument_model;
else
    sample_data.meta.instrument_model = 'Vemco Unknown';
end

if isfield(procHeader, 'instrument_firmware')
    sample_data.meta.instrument_firmware = procHeader.instrument_firmware;
else
    sample_data.meta.instrument_firmware = '';
end

if isfield(procHeader, 'instrument_serial_no')
    sample_data.meta.instrument_serial_no = procHeader.instrument_serial_no;
else
    sample_data.meta.instrument_serial_no = '';
end

time = data.TIME;

if isfield(procHeader, 'sampleInterval')
    sample_data.meta.instrument_sample_interval = procHeader.sampleInterval;
else
    sample_data.meta.instrument_sample_interval = median(diff(time*24*3600));
end

sample_data.dimensions = {};
sample_data.variables  = {};

% dimensions definition must stay in this order : T, Z, Y, X, others;
% to be CF compliant
% generate time data from header information
sample_data.dimensions{1}.name = 'TIME';
sample_data.dimensions{1}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{1}.name, 'type')));
sample_data.dimensions{1}.data = sample_data.dimensions{1}.typeCastFunc(time);
sample_data.dimensions{2}.name = 'LATITUDE';
sample_data.dimensions{2}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{2}.name, 'type')));
sample_data.dimensions{2}.data = sample_data.dimensions{2}.typeCastFunc(NaN);
sample_data.dimensions{3}.name = 'LONGITUDE';
sample_data.dimensions{3}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{3}.name, 'type')));
sample_data.dimensions{3}.data = sample_data.dimensions{3}.typeCastFunc(NaN);

% scan through the list of parameters that were read
% from the file, and create a variable for each
vars = fieldnames(data);
for k = 1:length(vars)
    
    if strncmp('TIME', vars{k}, 4), continue; end
    
    sample_data.variables{end+1}.dimensions     = [1 2 3];
    sample_data.variables{end  }.name           = vars{k};
    sample_data.variables{end  }.typeCastFunc   = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
    sample_data.variables{end  }.data           = sample_data.variables{end}.typeCastFunc(data.(vars{k}));
    sample_data.variables{end  }.comment        = comment.(vars{k});
end

end

function header = parseProcessedHeader(headerLines, dataHeaderLine)
%PARSEPROCESSEDHEADER Parses the data contained in the header of csv file
% produced by Logger Vue software. This includes the column layout of the 
% data in the .csv file. 
%
% Inputs:
%   headerLines - Cell array of strings, the lines in the processed header 
%                 section.
%   dataHeaderLine - the line describing the data layout.
%
% Outputs:
%   header      - struct containing information that was contained in the
%                 processed header section.
%

% example header lines from instrument
%
% Source File: C:\Field\Trip5934\Minilog-II-T_354314_20140213_1.vld
% Source Device: Minilog-II-T-354314
% Study Description: TAN100
% Minilog Initialized: 2013-08-04 05:03:50 (UTC+10)
% Study Start Time: 2013-08-05 00:00:00
% Study Stop Time: 2014-02-13 11:44:00
% Sample Interval: 00:01:00
% Date(yyyy-mm-dd),Time(hh:mm:ss),Temperature (�C)

  header = struct;
    
  sourceExpr = '^Source Device: ([\w-]+)-(\d+)$';
  startExpr  = '^Study Start Time: (.+)';
  stopExpr   = '^Study Stop Time: (.+)';
  sampleExpr = '^Sample Interval: (\d+):(\d+):(\d+)';
  
  header.nHeaderLines=numel(headerLines)+1;
  header.columns = regexp(dataHeaderLine,',','split');

  for k = 1:length(headerLines)
      
      % try source expr
      tkns = regexp(headerLines{k}, sourceExpr, 'tokens');
      if ~isempty(tkns)
          header.instrument_model     = tkns{1}{1};
          header.instrument_serial_no = tkns{1}{2};
          continue;
      end
      
      % then try startTime expr
      tkns = regexp(headerLines{k}, startExpr, 'tokens');
      if ~isempty(tkns)
          header.startTime = datenum(tkns{1}{1});
          continue;
      end
      
      % then try stopTime expr
      tkns = regexp(headerLines{k}, stopExpr, 'tokens');
      if ~isempty(tkns)
          header.stopTime = datenum(tkns{1}{1});
          continue;
      end
      
      % then try sample interval expr, return result in seconds
      tkns = regexp(headerLines{k}, sampleExpr, 'tokens');
      if ~isempty(tkns)
          header.sampleInterval = str2double(tkns{1}{1})*3600 + str2double(tkns{1}{2})*60 + str2double(tkns{1}{3});
          continue;
      end
      
  end
end