% bond portfolio strategy
% 
% The strategy will be to invest in
% - notes only:
%   - replicating real ETF behavior (almost no weight on bonds)
%   - real ETF behavior might only be a snapshot, and in reality notes
%     might have been prefered only due to different coupon rates
% - maturities between 7 and 10 years
% - only notes are taken, and in three month steps
% - re-balancing only due to expired notes; intermediate coupon cash-flows
%   are not directly re-invested

%% load data

% set data directory
dataDir = '../priv_bondPriceData';
fname = fullfile(dataDir, 'syntheticBondsLongFormat.mat');
load(fname)

%% define strategy parameters

GS = GlobalSettings;

% initial wealth
initWealth = 10000;

% define initial starting date and move to next business day
desiredInitDate = datenum('1975-01-02');
initDate = makeBusDate(desiredInitDate, 'follow', GS.Holidays, GS.WeekendInd);

% define TTM range
minDur = 7*365 + 2; % exclude 7 year notes
maxDur = 10*365;

%% restrict observations with regards to chosen backtest period
% subsetting the data, independent of bond strategy

% get observations within backtest period
xxInd = longPrices.Date >= initDate;
btPrices = longPrices(xxInd, :);

%% restrict observations with regards to strategy parameters
% - get TTM for each observation
% - eliminate observations outside of TTM range
% - eliminate 30-Year BONDs
% - eligible bonds and universe bonds change over time; in other words, a
%   given bond might be eligible / part of the universe only some part of
%   its lifetime; hence, eligibility has to be determined on the
%   granularity given by daily observations

% get time to maturity for each observation
btPrices = sortrows(btPrices, 'Date');
btPrices.CurrentMaturity = btPrices.Maturity - btPrices.Date;

% eliminate 30 year bonds
xxInds = strcmp(btPrices.TreasuryType, '30-Year BOND');
btPrices = btPrices(~xxInds, :);

% reduce to eligible bonds
xxEligible = btPrices.CurrentMaturity >= minDur & btPrices.CurrentMaturity <= maxDur;
btPrices = btPrices(xxEligible, :);


%% get eligible cash-flows

% get eligible bonds as Treasury array
eligibleBondIDs = unique(btPrices.TreasuryID);
xx = findInKeys(eligibleBondIDs, {allTreasuries.ID}');
eligibleBonds = allTreasuries(xx);

% get all cash-flow dates as matrix
pfCfDates = cfdates([eligibleBonds.AuctionDate]', [eligibleBonds.Maturity]', ...
    {eligibleBonds.Period}', {eligibleBonds.Basis}');

% transform cash-flow dates to table
pfCfTable = array2table(pfCfDates);
pfCfTable = [array2table(eligibleBondIDs, 'VariableNames', {'TreasuryID'}) , pfCfTable];
pfCfTable = stack(pfCfTable, tabnames(pfCfTable(:, 2:end)), ...
    'NewDataVariableName', 'Date',...
    'IndexVariableName', 'toDelete');
pfCfTable = pfCfTable(:, {'TreasuryID', 'Date'});
pfCfTable = pfCfTable(~isnan(pfCfTable.Date), :);
pfCfTable = sortrows(pfCfTable, 'Date');

% attach coupon payments
xxInfoTable = summaryTable(eligibleBonds);
pfCfTable = outerjoin(pfCfTable, xxInfoTable(:, {'TreasuryID', 'CouponRate'}), ...
    'Keys', 'TreasuryID', 'MergeKeys', true, 'Type', 'left');
pfCfTable.Properties.VariableNames{'CouponRate'} = 'CouponPayment';
pfCfTable.CouponPayment = pfCfTable.CouponPayment * 100;

%% join with bond prices

fullBondMarket = outerjoin(btPrices, pfCfTable, 'Keys', {'TreasuryID', 'Date'},...
    'MergeKeys', true, 'Type', 'left');

%% plot eligible bond prices and coupon payments

% get only coupon payments
xxInds = ~isnan(fullBondMarket.CouponPayment);
eligCoupons = fullBondMarket(xxInds, :);

subplot(2, 1, 1)
plot(eligCoupons.Date, eligCoupons.CouponPayment, '.')
datetick 'x'
grid on
grid minor
xlabel('date')
ylabel('Coupon payment')
title('Coupon payments of eligible bonds')


% plot eligible bonds

widePrices = unstack(btPrices(:, {'Date', 'TreasuryID', 'Price'}), 'Price', 'TreasuryID');

subplot(2, 1, 2)
plot(widePrices.Date, widePrices{:, 2:end}, 'Color', 0.4*[1, 1, 1])
datetick 'x'
grid on
grid minor
xlabel('date')
ylabel('price')
title('Eligible bond prices')

%% In 3D - rather useless

yVals = repmat(1:size(widePrices(:, 2:end), 2), size(widePrices, 1), 1);
plot3(widePrices.Date, yVals, widePrices{:, 2:end}, '.k')%, 'Color', 0.4*[1, 1, 1])
camlight
datetick 'x'
grid on
grid minor
xlabel('date')
ylabel('price')
title('Eligible bond prices')


%% visualize number of eligible bonds over time

% get number of eligible bonds per date
nEligibleBonds = grpstats(btPrices(:, {'Date', 'CurrentMaturity'}), 'Date');
nEligibleBonds = sortrows(nEligibleBonds, 'Date');

plot(nEligibleBonds.Date, nEligibleBonds.GroupCount, '.')
grid on
grid minor
datetick 'x'
xlabel('time')
ylabel('Number of eligible bonds')

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% start backtest
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% clear as much as possible
clearvars -except eligibleBonds fullBondMarket GS initWealth initDate minDur maDur

load devWkspace.mat

% get relevant quantities
bondMarket = fullBondMarket(:, {'Date', 'TreasuryID', 'Price', 'Maturity', 'CouponPayment'});

%% pre-allocate bond portfolio book-keeping

% get all backtest dates
allDates = unique(bondMarket.Date);

% preallocate cash account
xxVals = [allDates nan(length(allDates), 3)];
cashAccount = array2table(xxVals, 'VariableNames', ...
    {'Date', 'MorningCash', 'Coupons', 'Transactions'});
cashAccount{1, 'MorningCash'} = initWealth;

% initialize empty bond portfolio history
colNames = {'Date', 'TreasuryID', 'Price', 'MorningVolumes', 'Orders', 'CouponPayment', 'TransactionPrices'};
pfHistory = cell2table(cell(0, length(colNames)), 'VariableNames', colNames);

clearvars allDates xxVals colNames

%% visualize problem of initial bond allocation

thisDay = initDate;

% define grid of desired maturities
maturGrid = datetime(datevec(thisDay)) + calyears(7) + calmonths(3:3:36);
maturGrid = datenum(maturGrid);

% get prices
singleDayPrices = selRowsProp(bondMarket, 'Date', thisDay);

% visualize selection
doPlotting = false;
if doPlotting
    plot(singleDayPrices.Maturity, 1:length(singleDayPrices.Maturity), '.')
    hold on
    ylim = get(gca, 'YLim');
    for ii=1:length(maturGrid)
        plot(maturGrid(ii)*[1 1], ylim, '-r')
    end
    datetick 'x'
    xlabel('Maturity')
    ylabel('Number of bonds')
    title(['Desired maturities on ' datestr(thisDay)])
    grid on
    grid minor
end

%% select bond universe as bonds closest to desired maturities

% for each desired maturity, find closest bond
bondMaturities = singleDayPrices.Maturity;
xxInds = arrayfun(@(x)find(x-bondMaturities > 0, 1, 'last'), maturGrid);
currentUniverse = singleDayPrices(xxInds, :);
currentUniverse = sortrows(currentUniverse, 'Maturity');

%% generate orders for given market

% get desired buy value for each asset
nAss = size(currentUniverse, 1);
transCosts = 0.3;
cashLeft = initWealth;
nRemaining = nAss;

% preallocate orders
thisOrders = zeros(nAss, 1);
thisTransactionPrices = zeros(nAss, 1);

% start with smallest maturity
for ii=1:nAss
    % get market price
    currPrice = currentUniverse.Price(ii);
    
    % add transaction costs
    currTradePrice = currPrice + transCosts;
    thisTransactionPrices(ii, 1) = currTradePrice;
    
    % get desired value to buy
    cashPerAsset = cashLeft / nRemaining;
    
    % get number of full units that can be bought
    nUnits = floor(cashPerAsset / currTradePrice);
    thisOrders(ii, 1) = nUnits;
    
    % update cash values for next asset
    cashLeft = cashLeft - currTradePrice * nUnits;
    nRemaining = nRemaining - 1;

end

initOrders = currentUniverse(:, {'Date', 'TreasuryID', 'Price', 'CouponPayment'});
initOrders.Orders = thisOrders;
initOrders.TransactionPrices = thisTransactionPrices;
initOrders.MorningVolumes = zeros(size(thisTransactionPrices));

% get associated cash values for book-keeping
cashSpent = cashAccount{1, 'MorningCash'} - cashLeft;
cashAccount{1, 'Transactions'} = (-1)*cashSpent;

% attach to book-keeping
pfHistory = [pfHistory; initOrders];

%% conduct backtest
% for each day:
% - get current bond market
% - get current portfolio
% - get coupon payments
% - sell assets, attach orders and transaction prices to assets sold
% - buy assets, attach orders and transaction prices to assets bought

for ii=2:10000
    % get current date
    thisDate = cashAccount.Date(ii);
    
    % get current cash value
    currCashValue = sum(cashAccount{ii-1, 2:end}, 'omitnan');
    cashAccount{ii, 'MorningCash'} = currCashValue;
    
    % get current bond market
    currBondMarket = selRowsProp(bondMarket, 'Date', thisDate);
    
    % get current portfolio
    lastDate = cashAccount.Date(ii-1);
    currPf = selRowsProp(pfHistory, 'Date', lastDate);
    currPf{:, 'Date'} = thisDate;
    currPf.MorningVolumes = currPf.MorningVolumes + currPf.Orders;
    currPf{:, 'Orders'} = 0;
    currPf = currPf(currPf.MorningVolumes > 0, :);
    
    % get full information on current portfolio
    currAssetsMarket = outerjoin(currPf(:, {'Date', 'TreasuryID', 'MorningVolumes', 'Orders'}), ...
        bondMarket, 'Keys', {'Date', 'TreasuryID'},...
        'MergeKeys', true, 'Type', 'left');
    
    % get coupon payments
    couponPayments = sum(currAssetsMarket.MorningVolumes .* currAssetsMarket.CouponPayment, 'omitnan');
    cashAccount{ii, 'Coupons'} = couponPayments;
    
    % find selling assets
    currAssetsMarket.TTM = currAssetsMarket.Maturity - currAssetsMarket.Date;
    if any(currAssetsMarket.TTM < minDur + 5) % TRADE
        % find asset to sell
        indSell = currAssetsMarket.TTM < minDur + 5;
        oldAssets = currAssetsMarket;
        oldAssets.TransactionPrices = oldAssets.Price;
        oldAssets.Orders(indSell) = (-1)*oldAssets.MorningVolumes(indSell);
        oldAssets.TransactionPrices(indSell) = oldAssets.TransactionPrices(indSell) - transCosts;
        oldAssets.TTM = [];
        
        % compute cash that one gets from transactions
        cashFromSell = (-1)*(oldAssets.TransactionPrices(indSell) * oldAssets.Orders(indSell));
        
        % compute cash available
        cashAvailable = cashFromSell + sum(cashAccount{ii, 2:end}, 'omitnan');
    
        %% find asset to buy
        % buy the one with longest maturity
        [~, xxInd] = max(currBondMarket.Maturity);
        assetToBuy = currBondMarket(xxInd, :);
    
        % add transaction costs
        currTradePrice = assetToBuy.Price + transCosts;
        assetToBuy.TransactionPrices = currTradePrice;
        
        % get number of full units that can be bought
        nUnits = floor(cashAvailable/ currTradePrice);
        assetToBuy.MorningVolumes = 0;
        assetToBuy.Orders = nUnits;
        
        % write transaction costs into cash account
        cashAccount.Transactions(ii) = (-1)*(currTradePrice * nUnits) + cashFromSell;
        
        currAssetsMarket = [oldAssets; assetToBuy];
        currAssetsMarket.Maturity = [];
        
    else % NO TRADE
        % attach orders
        currAssetsMarket.Maturity = currAssetsMarket.Price;
        currAssetsMarket.Properties.VariableNames{'Maturity'} = 'TransactionPrices';
        currAssetsMarket.TTM = [];
    end
    
    % attach orders to portfolio history
    pfHistory = [pfHistory; currAssetsMarket];
end

%% get bond portfolio history

% get market values of individual positions
pfHistory.EveningVolumes = pfHistory.MorningVolumes + pfHistory.Orders;
pfHistory.MarketValue = pfHistory.EveningVolumes .* pfHistory.Price;

% aggregate per date
bondValues = grpstats(pfHistory(:, {'Date', 'MarketValue'}), 'Date', 'sum');
bondValues.Properties.VariableNames{'sum_MarketValue'} = 'MarketValue';

% get cash account values in the evening
cashAccount.Cash = sum(cashAccount{:, 2:end}, 2, 'omitnan');

% join bond values and cash position
pfValues = outerjoin(bondValues(:, {'Date', 'MarketValue'}), ...
    cashAccount(:, {'Date', 'Cash'}), 'Keys', 'Date', 'MergeKeys', true, 'Type', 'left');

pfValues = sortrows(pfValues, 'Date');
pfValues.FullValue = pfValues.MarketValue + pfValues.Cash;

%%

plot(pfValues.Date, pfValues.FullValue)
datetick 'x'
grid on
grid minor

%% Questions / challenges
% - some kind of generateOrders
% - when is cash burnt, and for what?
% - how is bond portfolio represented?
% - how to get cfs and maturities?
% - how to get exit / sell days for bonds?



%% define portfolio object
% bond portfolio remains the same until next selling date
% - cash position changes
% - volumes could change
% - long table:
%   - assetLabel
%   - price
%   - volume

%% define universe
% - get cash-flow dates
% - get universe change date
% - define universe change: 
%   - which asset gets removed
%   - which asset gets in
%   - what if day is simultaneously cash-flow date?





