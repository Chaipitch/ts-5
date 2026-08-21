public class GeminiCalloutService {

    private static final String API_KEY = 'AQ.Ab8RN6LC0UveQZoM2TMOiBpITcCncuPN_zE9HLy_L4K0J8-aLw'; 
    private static final String MODEL = 'gemini-3.1-flash-lite'; 
    private static final String ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models/' + MODEL + ':generateContent?key=' + API_KEY;    

    @future(callout=true)
    public static void askGemini(String prompt, String recordId) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();

        Schema.SObjectType objectType = ((Id)recordId).getSObjectType();
        String apiName = ((Id)recordId).getSObjectType().getDescribe().getName();

        system.debug('objectType>>>'+objectType);
        system.debug('apiName>>>>>'+apiName);

        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(60000);
        
        // Construct JSON Payload
        Map<String, Object> rootPayload = new Map<String, Object>();
        List<Object> contentsList = new List<Object>();
        Map<String, Object> contentMap = new Map<String, Object>();
        List<Object> partsList = new List<Object>();
        Map<String, Object> textMap = new Map<String, Object>();
        
        textMap.put('text', prompt);
        partsList.add(textMap);
        contentMap.put('parts', partsList);
        contentsList.add(contentMap);
        rootPayload.put('contents', contentsList);

        Map<String, Object> generationConfig = new Map<String, Object>();
        generationConfig.put('responseMimeType', 'application/json');
        rootPayload.put('generationConfig', generationConfig);
        
        request.setBody(JSON.serialize(rootPayload));
        
        try {
            HttpResponse response = http.send(request);
            
            if (response.getStatusCode() == 200) {
                // Delegate all parsing, normalization, and Account updating
                GeminiAccountResponseParser.processAndSaveAccount(response.getBody(), recordId);
            } else {
                System.debug('Error Status: ' + response.getStatus());
                System.debug('Error Body: ' + response.getBody());
            }
        } catch (Exception e) {
            System.debug('Exception encountered at line ' + e.getLineNumber() + ': ' + e.getMessage());
        }
    }
}