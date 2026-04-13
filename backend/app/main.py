from fastapi import FastAPI, UploadFile, File, HTTPException
from app.worker import extract_ingredients_task, match_recipes_task, refine_recipe_task, celery_app
from celery import chain
from celery.result import AsyncResult

app = FastAPI()

@app.get("/")
async def root():
    return {
        "message": "FridgeAI API is online!",
        "endpoints": ["/docs", "/upload", "/status/{id}"]
    }

@app.post("/upload-fridge")
async def upload_fridge(file: UploadFile = File(...)):
    # 1. Receive the file
    content = await file.read()
    
    # 2. This creates a pipeline: Extract -> Match
    # The output of Task 1 (ingredients) is automatically passed to Task 2
    workflow = chain(
        extract_ingredients_task.s(content.hex()),
        match_recipes_task.s(),
        refine_recipe_task.s()
    )
    
    task = workflow.apply_async()
    return {"task_id": task.id, "status": "Processing request1: Analyzing photo and finding recipes..."}


@app.get("/tasks/{task_id}")
async def get_task_status(task_id: str):
    """
    The client uses the task_id obtained during image upload 
    to query this endpoint and check if the recipe generation is complete.
    """
    # Query Redis for the current status of the task using the task_id
    task_result = AsyncResult(task_id, app=celery_app)
    
    # Construct the response payload to return to the client
    response = {
        "task_id": task_id,
        "status": task_result.status, # Status is typically PENDING, STARTED, SUCCESS, or FAILURE
        "result": None
    }
    
    # If the task is finished, attach the result (the generated recipe)
    if task_result.ready():
        if task_result.successful():
            response["result"] = task_result.result
        else:
            # If the task execution failed, capture the exception information here
            response["status"] = "FAILURE"
            response["result"] = str(task_result.info)
            
    return response