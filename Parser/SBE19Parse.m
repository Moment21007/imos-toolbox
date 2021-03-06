function sample_data = SBE19Parse( filename, mode )
%SBE19PARSE Parses a .cnv or .hex data file from a Seabird SBE19plus v2 or a .cnv SBE16plus
% CTD recorder.
%
% This function is able to read in a .cnv or .hex data file retrieved 
% from a Seabird SBE19plus V2 or a .cnv from a SBE16plus CTD recorder. It makes use of two lower level
% functions, readSBE19hex and readSBE19cnv. The files consist of up to
% three sections: 
%
%   - instrument header - header information as retrieved from the instrument. 
%                         These lines are prefixed with '*'.
%   - processed header  - header information generated by SBE Data Processing. 
%                         These lines are prefixed with '#'. Not contained
%                         in .hex files.
%   - data              - Rows of data.
%
% This function reads in the header sections, and delegates to the two file
% specific sub functions to process the data.
%
% Inputs:
%   filename    - cell array of files to import (only one supported).
%   mode        - Toolbox data type mode.
%
% Outputs:
%   sample_data - Struct containing sample data.
%
% Author:       Paul McCarthy <paul.mccarthy@csiro.au>
% Contributor:  Brad Morris <b.morris@unsw.edu.au>
% 				Guillaume Galibert <guillaume.galibert@utas.edu.au>
%

%
% Copyright (C) 2017, Australian Ocean Data Network (AODN) and Integrated 
% Marine Observing System (IMOS).
%
% This program is free software: you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation version 3 of the License.
%
% This program is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
% GNU General Public License for more details.

% You should have received a copy of the GNU General Public License
% along with this program.
% If not, see <https://www.gnu.org/licenses/gpl-3.0.en.html>.
%
  narginchk(1,2);

  if ~iscellstr(filename)
    error('filename must be a cell array of strings'); 
  end

  % only one file supported currently
  filename = filename{1};
  
  % read in every line in the file, separating
  % them out into each of the three sections
  
  %instHeaderLines = {};
  %procHeaderLines = {};
  
  [dataLines, instHeaderLines, procHeaderLines] = readSBEcnv( filename, mode );
  
  % read in the raw instrument header
  instHeader = parseInstrumentHeader(instHeaderLines, mode);
  procHeader = parseProcessedHeader( procHeaderLines);
  
  % use the appropriate subfunction to read in the data
  % assume that anything with a suffix not equal to .hex
  % is a .cnv file
  [~, ~, ext] = fileparts(filename);
  
  if strcmpi(ext, '.hex')
      [data, comment] = readSBE19hex(dataLines, instHeader);
  else
      [data, comment] = readSBEcnvData(dataLines, instHeader, procHeader, mode);
  end
  
  % create sample data struct,
  % and copy all the data in
  sample_data = struct;
  
  sample_data.toolbox_input_file    = filename;
  sample_data.meta.featureType      = mode;
  sample_data.meta.instHeader       = instHeader;
  sample_data.meta.procHeader       = procHeader;
  
  sample_data.meta.instrument_make = 'Seabird';
  if isfield(instHeader, 'instrument_model')
    sample_data.meta.instrument_model = instHeader.instrument_model;
  else
    sample_data.meta.instrument_model = 'SBE19';
  end
  
  if isfield(instHeader, 'instrument_firmware')
    sample_data.meta.instrument_firmware = instHeader.instrument_firmware;
  else
    sample_data.meta.instrument_firmware = '';
  end
  
  if isfield(instHeader, 'instrument_serial_no')
    sample_data.meta.instrument_serial_no = instHeader.instrument_serial_no;
  else
    sample_data.meta.instrument_serial_no = '';
  end
  
  time = genTimestamps(instHeader, data);
  
  if isfield(instHeader, 'sampleInterval')
    sample_data.meta.instrument_sample_interval = instHeader.sampleInterval;
  else
    sample_data.meta.instrument_sample_interval = median(diff(time*24*3600));
  end
  
  sample_data.dimensions = {};  
  sample_data.variables  = {};
  
  switch mode
      case 'profile'
          if ~isfield(procHeader, 'binSize')
              disp(['Warning : ' sample_data.toolbox_input_file ...
                  ' has not been vertically binned as per ' ...
                  'http://help.aodn.org.au/help/sites/help.aodn.org.au/' ...
                  'files/ANMN%20CTD%20Processing%20Procedures.pdf']);
          end
              
          % dimensions creation
          iVarPRES_REL = NaN;
          iVarDEPTH = NaN;
          isZ = false;
          vars = fieldnames(data);
          nVars = length(vars);
          for k = 1:nVars
              if strcmpi('DEPTH', vars{k})
                  iVarDEPTH = k;
                  isZ = true;
                  break;
              end
              if strcmpi('PRES_REL', vars{k})
                  iVarPRES_REL = k;
                  isZ = true;
              end
              if ~isnan(iVarDEPTH) && ~isnan(iVarPRES_REL), break; end
          end
          
          if ~isZ
              error('There is no pressure or depth information in this file to use it in profile mode');
          end
          
          depthComment = '';
          if ~isnan(iVarDEPTH)
              iVarZ = iVarDEPTH;
              depthData = data.(vars{iVarDEPTH});
          else
              iVarZ = iVarPRES_REL;
              depthData = data.(vars{iVarPRES_REL});
              presComment = ['relative '...
                  'pressure measurements (calibration offset '...
                  'usually performed to balance current '...
                  'atmospheric pressure and acute sensor '...
                  'precision at a deployed depth)'];
              depthComment  = ['Depth computed from '...
                  presComment ', assuming 1dbar ~= 1m.'];
          end
          
          % let's distinguish descending/ascending parts of the profile
          nData = length(data.(vars{iVarZ}));
          zMax = max(data.(vars{iVarZ}));
          posZMax = find(data.(vars{iVarZ}) == zMax, 1, 'last'); % in case there are many times the max value
          iD = [true(posZMax, 1); false(nData-posZMax, 1)];
          
          nD = sum(iD);
          nA = sum(~iD);
          MAXZ = max(nD, nA);
          
          dNaN = nan(MAXZ-nD, 1);
          aNaN = nan(MAXZ-nA, 1);
          
          if nA == 0
              sample_data.dimensions{1}.name            = 'DEPTH';
              sample_data.dimensions{1}.typeCastFunc    = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{1}.name, 'type')));
              sample_data.dimensions{1}.data            = sample_data.dimensions{1}.typeCastFunc(depthData);
              sample_data.dimensions{1}.comment         = depthComment;
              sample_data.dimensions{1}.axis            = 'Z';
              
              sample_data.variables{end+1}.name         = 'PROFILE';
              sample_data.variables{end}.typeCastFunc   = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
              sample_data.variables{end}.data           = sample_data.variables{end}.typeCastFunc(1);
              sample_data.variables{end}.dimensions     = [];
          else
              sample_data.dimensions{1}.name            = 'MAXZ';
              sample_data.dimensions{1}.typeCastFunc    = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{1}.name, 'type')));
              sample_data.dimensions{1}.data            = sample_data.dimensions{1}.typeCastFunc(1:1:MAXZ);
              
              sample_data.dimensions{2}.name            = 'PROFILE';
              sample_data.dimensions{2}.typeCastFunc    = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{2}.name, 'type')));
              sample_data.dimensions{2}.data            = sample_data.dimensions{2}.typeCastFunc([1, 2]);
              
              disp(['Warning : ' sample_data.toolbox_input_file ...
                  ' is not IMOS CTD profile compliant. See ' ...
                  'http://help.aodn.org.au/help/sites/help.aodn.org.au/' ...
                  'files/ANMN%20CTD%20Processing%20Procedures.pdf']);
          end
          
          % Add TIME, DIRECTION and POSITION infos
          descendingTime = time(iD);
          descendingTime = descendingTime(1);
          
          if nA == 0
              ascendingTime = [];
              dimensions = [];
          else
              ascendingTime = time(~iD);
              ascendingTime = ascendingTime(1);
              dimensions = 2;
          end
          
          sample_data.variables{end+1}.dimensions = dimensions;
          sample_data.variables{end}.name         = 'TIME';
          sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          sample_data.variables{end}.data         = sample_data.variables{end}.typeCastFunc([descendingTime, ascendingTime]);
          sample_data.variables{end}.comment      = 'First value over profile measurement.';
          
          sample_data.variables{end+1}.dimensions = dimensions;
          sample_data.variables{end}.name         = 'DIRECTION';
          sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          if nA == 0
              sample_data.variables{end}.data     = {'D'};
          else
              sample_data.variables{end}.data     = {'D', 'A'};
          end
          
          sample_data.variables{end+1}.dimensions = dimensions;
          sample_data.variables{end}.name         = 'LATITUDE';
          sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          if nA == 0
              sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc(NaN);
          else
              sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc([NaN, NaN]);
          end
          
          sample_data.variables{end+1}.dimensions = dimensions;
          sample_data.variables{end}.name         = 'LONGITUDE';
          sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          if nA == 0
              sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc(NaN);
          else
              sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc([NaN, NaN]);
          end
          
          sample_data.variables{end+1}.dimensions = dimensions;
          sample_data.variables{end}.name         = 'BOT_DEPTH';
          sample_data.variables{end}.comment      = 'Bottom depth measured by ship-based acoustic sounder at time of CTD cast.';
          sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          if nA == 0
              sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc(NaN);
          else
              sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc([NaN, NaN]);
          end
          
          % Manually add variable DEPTH if multiprofile and doesn't exist
          % yet
          if isnan(iVarDEPTH) && (nA ~= 0)
              sample_data.variables{end+1}.dimensions = [1 2];
              
              sample_data.variables{end}.name         = 'DEPTH';
              sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));

              % we need to padd data with NaNs so that we fill MAXZ
              % dimension
              sample_data.variables{end}.data         = sample_data.variables{end}.typeCastFunc([[depthData(iD); dNaN], [depthData(~iD); aNaN]]);

              sample_data.variables{end}.comment      = depthComment;
              sample_data.variables{end}.axis         = 'Z';
          end
          
          % scan through the list of parameters that were read
          % from the file, and create a variable for each
          for k = 1:nVars
              % we skip TIME and DEPTH
              if strcmpi('TIME', vars{k}), continue; end
              if strcmpi('DEPTH', vars{k}) && (nA == 0), continue; end

              sample_data.variables{end+1}.dimensions = [1 dimensions];
              
              sample_data.variables{end}.name         = vars{k};
              sample_data.variables{end}.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
              if nA == 0
                  sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc(data.(vars{k})(iD));
              else
                  % we need to padd data with NaNs so that we fill MAXZ
                  % dimension
                  sample_data.variables{end}.data     = sample_data.variables{end}.typeCastFunc([[data.(vars{k})(iD); dNaN], [data.(vars{k})(~iD); aNaN]]);
              end
              sample_data.variables{end}.comment      = comment.(vars{k});
              
              if ~any(strcmpi(vars{k}, {'TIME', 'DEPTH'}))
                  sample_data.variables{end}.coordinates = 'TIME LATITUDE LONGITUDE DEPTH';
              end
              
              if strncmp('PRES_REL', vars{k}, 8)
                  % let's document the constant pressure atmosphere offset previously
                  % applied by SeaBird software on the absolute presure measurement
                  sample_data.variables{end}.applied_offset = sample_data.variables{end}.typeCastFunc(-14.7*0.689476);
              end
          end
          
      case 'timeSeries'
          % dimensions creation
          sample_data.dimensions{1}.name            = 'TIME';
          sample_data.dimensions{1}.typeCastFunc    = str2func(netcdf3ToMatlabType(imosParameters(sample_data.dimensions{1}.name, 'type')));
          % generate time data from header information
          sample_data.dimensions{1}.data            = sample_data.dimensions{1}.typeCastFunc(time);
          
          sample_data.variables{end+1}.name           = 'TIMESERIES';
          sample_data.variables{end}.typeCastFunc     = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          sample_data.variables{end}.data             = sample_data.variables{end}.typeCastFunc(1);
          sample_data.variables{end}.dimensions       = [];
          sample_data.variables{end+1}.name           = 'LATITUDE';
          sample_data.variables{end}.typeCastFunc     = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          sample_data.variables{end}.data             = sample_data.variables{end}.typeCastFunc(NaN);
          sample_data.variables{end}.dimensions       = [];
          sample_data.variables{end+1}.name           = 'LONGITUDE';
          sample_data.variables{end}.typeCastFunc     = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          sample_data.variables{end}.data             = sample_data.variables{end}.typeCastFunc(NaN);
          sample_data.variables{end}.dimensions       = [];
          sample_data.variables{end+1}.name           = 'NOMINAL_DEPTH';
          sample_data.variables{end}.typeCastFunc     = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
          sample_data.variables{end}.data             = sample_data.variables{end}.typeCastFunc(NaN);
          sample_data.variables{end}.dimensions       = [];
          
          % scan through the list of parameters that were read
          % from the file, and create a variable for each
          vars = fieldnames(data);
          coordinates = 'TIME LATITUDE LONGITUDE NOMINAL_DEPTH';
          for k = 1:length(vars)
              
              if strncmp('TIME', vars{k}, 4), continue; end
              
              % dimensions definition must stay in this order : T, Z, Y, X, others;
              % to be CF compliant
              sample_data.variables{end+1}.dimensions   = 1;
              
              sample_data.variables{end  }.name         = vars{k};
              sample_data.variables{end  }.typeCastFunc = str2func(netcdf3ToMatlabType(imosParameters(sample_data.variables{end}.name, 'type')));
              sample_data.variables{end  }.data         = sample_data.variables{end}.typeCastFunc(data.(vars{k}));
              sample_data.variables{end  }.comment      = comment.(vars{k});
              sample_data.variables{end  }.coordinates  = coordinates;
              
              if strncmp('PRES_REL', vars{k}, 8)
                  % let's document the constant pressure atmosphere offset previously
                  % applied by SeaBird software on the absolute presure measurement
                  sample_data.variables{end}.applied_offset = sample_data.variables{end}.typeCastFunc(-14.7*0.689476);
              end
          end
  
  end
end

function header = parseInstrumentHeader(headerLines, mode)
%PARSEINSTRUMENTHEADER Parses the header lines from a SBE19/37 .cnv file.
% Returns the header information in a struct.
%
% Inputs:
%   headerLines - cell array of strings, the lines of the header section.
%   mode        - Toolbox data type mode.
%
% Outputs:
%   header      - struct containing information that was in the header
%                 section.
%
header = struct;

% there's no real structure to the header information, which
% is annoying. my approach is to use various regexes to search
% for info we want, and to ignore everything else. inefficient,
% but it's the nicest way i can think of

headerExpr   = '^\*\s*(SBE \S+|SeacatPlus)\s+V\s+(\S+)\s+SERIAL NO.\s+(\d+)';
%BDM (18/2/2011) - new header expressions to reflect newer SBE header info
headerExpr2  = '<HardwareData DeviceType=''(\S+)'' SerialNumber=''(\S+)''>';
headerExpr3  = 'Sea-Bird (.*?) *?Data File\:';
scanExpr     = 'number of scans to average = (\d+)';
scanExpr2    = '*\s+ <ScansToAverage>(\d+)</ScansToAverage>';
memExpr      = 'samples = (\d+), free = (\d+), casts = (\d+)';
sampleExpr   = ['sample interval = (\d+) (\w+), ' ...
    'number of measurements per sample = (\d+)'];
sampleExpr2  ='*\s+ <Samples>(\d+)</Samples>';
profExpr     = '*\s+ <Profiles>(\d+)</Profiles>';
modeExpr     = 'mode = (\w+), minimum cond freq = (\d*), pump delay = (\d*)';
pressureExpr = 'pressure sensor = (strain gauge|quartz)';
voltExpr     = 'Ext Volt ?(\d+) = (yes|no)';
outputExpr   = 'output format = (.*)$';
castExpr     = ['(?:cast|hdr)\s+(\d+)\s+' ...
    '(\d+ \w+ \d+ \d+:\d+:\d+)\s+'...
    'samples (\d+) to (\d+), (?:avg|int) = (\d+)'];
%Replaced castExpr to be specific to NSW-IMOS PH NRT
%Note: also replace definitions below in 'case 9'
%BDM 24/01/2011
castExpr2    = 'Cast Time = (\w+ \d+ \d+ \d+:\d+:\d+)';
intervalExpr = 'interval = (.*): ([\d\.\+)$';
sbe38Expr    = 'SBE 38 = (yes|no), Gas Tension Device = (yes|no)';
optodeExpr   = 'OPTODE = (yes|no)';
voltCalExpr  = 'volt (\d): offset = (\S+), slope = (\S+)';
otherExpr    = '^\*\s*([^\s=]+)\s*=\s*([^\s=]+)\s*$';
firmExpr     = '<FirmwareVersion>(\S+)</FirmwareVersion>';
firmExpr2    = '^\*\s*FirmwareVersion:\s*(\S+)'; %SBE39plus
sensorId     = '<Sensor id=''(.*\S+.*)''>';
sensorType   = '<[tT]ype>(.*\S+.*)</[tT]ype>';
serialExpr   = '^\*\s*SerialNumber:\s*(\S+)'; %SBE39plus
serialExpr2  = '^\*\s*SEACAT PROFILER\s*V(\S+)\s*SN\s*(\S+)'; %SEACAT PROFILER

exprs = {...
    headerExpr   headerExpr2    headerExpr3    scanExpr     ...
    scanExpr2    memExpr      sampleExpr   ...
    sampleExpr2  profExpr       modeExpr     pressureExpr ...
    voltExpr     outputExpr   ...
    castExpr     castExpr2   intervalExpr ...
    sbe38Expr    optodeExpr   ...
    voltCalExpr  otherExpr ...
    firmExpr     sensorId   sensorType firmExpr2 serialExpr serialExpr2};

for k = 1:length(headerLines)
    
    % try each of the expressions
    for m = 1:length(exprs)
        
        % until one of them matches
        tkns = regexp(headerLines{k}, exprs{m}, 'tokens');
        if ~isempty(tkns)
            
            % yes, ugly, but easiest way to figure out which regex we're on
            switch m
                
                % header
                case 1
                    if ~isfield(header, 'instrument_model')
                        header.instrument_model = tkns{1}{1};
                    end
                    header.instrument_firmware  = tkns{1}{2};
                    header.instrument_serial_no = tkns{1}{3};
                    
                % header2
                case 2
                    if ~isfield(header, 'instrument_model')
                        header.instrument_model = tkns{1}{1};
                    end
                    header.instrument_serial_no = tkns{1}{2};
                    
                % header3
                case 3
                    header.instrument_model     = strrep(tkns{1}{1}, ' ', '');
                    
                % scan
                case 4
                    header.scanAvg = str2double(tkns{1}{1});
                    
                % scan2
                case 5
                    header.scanAvg = str2double(tkns{1}{1});
                    %%ADDED by Loz
                    header.castAvg = header.scanAvg;
                    
                % mem
                case 6
                    header.numSamples = str2double(tkns{1}{1});
                    header.freeMem    = str2double(tkns{1}{2});
                    header.numCasts   = str2double(tkns{1}{3});
                    
                % sample
                case 7
                    header.sampleInterval        = str2double(tkns{1}{1});
                    header.mesaurementsPerSample = str2double(tkns{1}{2});
                    
                % sample2
                case 8
                    header.castEnd = str2double(tkns{1}{1});
                
                % profile
                case 9
                    header.castNumber = str2double(tkns{1}{1});    
                    
                % mode
                case 10
                    header.mode         = tkns{1}{1};
                    header.minCondFreq  = str2double(tkns{1}{2});
                    header.pumpDelay    = str2double(tkns{1}{3});
                    
                % pressure
                case 11
                    header.pressureSensor = tkns{1}{1};
                    
                % volt
                case 12
                    for n = 1:length(tkns),
                        header.(['ExtVolt' tkns{n}{1}]) = tkns{n}{2};
                    end
                    
                % output
                case 13
                    header.outputFormat = tkns{1}{1};
                    
                % cast
                case 14
                    if ~isfield(header, 'castStart')
                        header.castNumber = str2double(tkns{1}{1});
                        header.castDate   = datenum(   tkns{1}{2}, 'dd mmm yyyy HH:MM:SS');
                        header.castStart  = str2double(tkns{1}{3});
                        header.castEnd    = str2double(tkns{1}{4});
                        header.castAvg    = str2double(tkns{1}{5});
                    else
                        % in timeSeries mode we only need the first occurence
                        % but in profile mode we require all cast dates
                        if strcmpi(mode, 'profile')
                            header.castNumber(end+1) = str2double(tkns{1}{1});
                            header.castDate(end+1)   = datenum(   tkns{1}{2}, 'dd mmm yyyy HH:MM:SS');
                            header.castStart(end+1)  = str2double(tkns{1}{3});
                            header.castEnd(end+1)    = str2double(tkns{1}{4});
                            header.castAvg(end+1)    = str2double(tkns{1}{5});
                        end
                    end
                    
                % cast2
                case 15                    
                    header.castDate   = datenum(tkns{1}{1}, 'mmm dd yyyy HH:MM:SS');
                    
                % interval
                case 16
                    header.resolution = tkns{1}{1};
                    header.interval   = str2double(tkns{1}{2});
                    
                % sbe38 / gas tension device
                case 17
                    header.sbe38 = tkns{1}{1};
                    header.gtd   = tkns{1}{2};
                    
                % optode
                case 18
                    header.optode = tkns{1}{1};
                    
                % volt calibration
                case 19
                    header.(['volt' tkns{1}{1} 'offset']) = str2double(tkns{1}{2});
                    header.(['volt' tkns{1}{1} 'slope'])  = str2double(tkns{1}{3});
                    
                % name = value
                case 20
                    header.(genvarname(tkns{1}{1})) = tkns{1}{2};
                    
                %firmware version
                case 21
                    header.instrument_firmware  = tkns{1}{1};
                
                %sensor id
                case 22
                    if ~isfield(header, 'sensorIds')
                        header.sensorIds = {};
                    end
                    header.sensorIds{end+1}  = tkns{1}{1};
                    
                %sensor type
                case 23
                    if ~isfield(header, 'sensorTypes')
                        header.sensorTypes = {};
                    end
                    header.sensorTypes{end+1}  = tkns{1}{1};

                %FirmwareVersion, SBE39plus cnv
                case 24
                    header.instrument_firmware  = tkns{1}{1};
                    
                % SerialNumber, SBE39plus cnv
                case 25
                    header.instrument_serial_no = tkns{1}{1};
                    
                % old SEACAT PROFILER serial number format
                % example "* SEACAT PROFILER V2.1a SN 597   10/15/11  10:02:56.721"
                case 26
                    % is tkns{1}{1} firmware version?
                    header.instrument_serial_no = tkns{1}{2};

            end
            break;
        end
    end
end
end

function header = parseProcessedHeader(headerLines)
%PARSEPROCESSEDHEADER Parses the data contained in the header added by SBE
% Data Processing. This includes the column layout of the data in the .cnv 
% file. 
%
% Inputs:
%   headerLines - Cell array of strings, the lines in the processed header 
%                 section.
%
% Outputs:
%   header      - struct containing information that was contained in the
%                 processed header section.
%

  header = struct;
  header.columns = {};
  
  nameExpr = 'name \d+ = (.+):';
  nvalExpr = 'nvalues = (\d+)';
  badExpr  = 'bad_flag = (.*)$';
  %BDM (18/02/2011) - added to get start time
  startExpr = 'start_time = (\w+ \d+ \d+ \d+:\d+:\d+)';
  volt0Expr = 'sensor \d+ = Extrnl Volt  0  (.+)';
  volt1Expr = 'sensor \d+ = Extrnl Volt  1  (.+)';
  volt2Expr = 'sensor \d+ = Extrnl Volt  2  (.+)';
  binExpr   = 'binavg_binsize = (\d+)';
  
  for k = 1:length(headerLines)
    
    % try name expr
    tkns = regexp(headerLines{k}, nameExpr, 'tokens');
    if ~isempty(tkns)
      header.columns{end+1} = tkns{1}{1};
      continue; 
    end
    
    % then try nvalues expr
    tkns = regexp(headerLines{k}, nvalExpr, 'tokens');
    if ~isempty(tkns)
      header.nValues = str2double(tkns{1}{1});
      continue;
    end
    
    % then try bad flag expr
    tkns = regexp(headerLines{k}, badExpr, 'tokens');
    if ~isempty(tkns)
      header.badFlag = str2double(tkns{1}{1});
      continue;
    end
    
    %BDM (18/02/2011) - added to get start time
    % then try startTime expr
    tkns = regexp(headerLines{k}, startExpr, 'tokens');
    if ~isempty(tkns)
      header.startTime = datenum(tkns{1}{1}, 'mmm dd yyyy HH:MM:SS');
      continue;
    end
    
    % then try volt exprs
    tkns = regexp(headerLines{k}, volt0Expr, 'tokens');
    if ~isempty(tkns)
      header.volt0Expr = tkns{1}{1};
      continue;
    end
    tkns = regexp(headerLines{k}, volt1Expr, 'tokens');
    if ~isempty(tkns)
      header.volt1Expr = tkns{1}{1};
      continue;
    end
    tkns = regexp(headerLines{k}, volt2Expr, 'tokens');
    if ~isempty(tkns)
      header.volt2Expr = tkns{1}{1};
      continue;
    end
    
    % then try bin expr
    tkns = regexp(headerLines{k}, binExpr, 'tokens');
    if ~isempty(tkns)
      header.binSize = str2double(tkns{1}{1});
      continue;
    end
  end
end

function time = genTimestamps(instHeader, data)
%GENTIMESTAMPS Generates timestamps for the data. Horribly ugly. I shouldn't 
% have to have a function like this, but the .cnv files do not necessarily 
% provide timestamps for each sample.
%
  
  % time may have been present in the sample 
  % data - if so, we don't have to do any work
  if isfield(data, 'TIME')
      time = data.TIME;
      return;
  end
  
  % To generate timestamps for the CTD data, we need to know:
  %   - start time
  %   - sample interval
  %   - number of samples
  %
  % The SBE19 header information does not necessarily provide all, or any
  % of this information. .
  %
  start    = 0;
  interval = 0.25;
    
  % figure out number of samples by peeking at the 
  % number of values in the first column of 'data'
  f = fieldnames(data);
  nSamples = length(data.(f{1}));
  
  % try and find a start date - use castDate if present
  if isfield(instHeader, 'castDate')
    start = instHeader.castDate;
  end
  
  % if castStart is present then it means we have several cast records
  if isfield(instHeader, 'castStart')
      time = NaN(1, instHeader.castEnd(end));
      for i=1:length(instHeader.castNumber)
          for j=instHeader.castStart(i):instHeader.castEnd(i)
              time(j) = instHeader.castDate(i) + (j-instHeader.castStart(i))*instHeader.castAvg(i)/(3600*24);
          end
      end
      return;
  end
  
  % if scanAvg field is present, use it to determine the interval
  if isfield(instHeader, 'scanAvg')
    interval = (0.25 * instHeader.scanAvg) / 86400;
  end
  
  % if one of the columns is 'Scan Count', use the 
  % scan count number as the basis for the timestamps 
  if isfield(data, 'ScanCount')
    time = ((data.ScanCount - 1) ./ 345600) + cStart;
  % if scan count is not present, calculate the 
  % timestamps from start, end and interval
  else
    time = (start:interval:start + (nSamples - 1) * interval)';
  end
end


